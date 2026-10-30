// USER1 accesses 32 bytes at a time: op 3 reads, op 4 writes with byte masks and reads back.
module memory_debug (
    input wire clk,
    input wire rst,
    input wire calibrated,
    input wire request,
    input wire [511:0] packet,
    output reg acknowledge = 0,
    output reg [511:0] response = 0,
    output wire busy,
    input wire cmd_ready,
    input wire wr_ready,
    output wire cmd_en,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] wr_data,
    output wire wr_en,
    output wire [31:0] wr_mask,
    input wire rd_valid,
    input wire [255:0] rd_data
);

    localparam IDLE = 0;
    localparam WRITE = 1;
    localparam READ = 2;
    localparam WAIT_READ = 3;
    localparam CHECK = 4;
    localparam FINISH = 5;
    reg [2:0] state = IDLE;
    reg [31:0] seq, address, mask;
    reg [255:0] payload, readback;
    reg write_command, failed;
    reg [31:0] watchdog;
    reg [31:0] mismatch;
    wire issue = cmd_ready && (state == READ || state == WRITE && wr_ready);
    assign busy = state != IDLE;
    assign cmd_en = issue;
    assign wr_en = issue && state == WRITE;
    assign cmd = state == WRITE ? 3'b0 : 3'b1;
    assign addr = {1'b0, address[29:2]};
    assign wr_data = payload;
    assign wr_mask = mask;
    integer lane;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            acknowledge <= request;
            response <= 0;
        end else begin
            if (busy) begin
                watchdog <= watchdog + 1'b1;
                if (issue || rd_valid) watchdog <= 0;
            end
            case (state)
                IDLE:
                if (request != acknowledge) begin
                    seq <= packet[63:32];
                    address <= packet[95:64];
                    mask <= packet[255:224];
                    payload <= packet[511:256];
                    write_command <= packet[39:32] == 4;
                    failed <= 0;
                    watchdog <= 0;
                    mismatch <= 0;
                    readback <= 0;
                    if (!calibrated || packet[31:0] != 32'h44445233 || packet[95:94] != 0 || packet[68:64] != 0 ||
                       packet[127:96] != 1 || (packet[39:32] != 3 && packet[39:32] != 4)) begin
                        failed <= 1;
                        state <= FINISH;
                    end else state <= packet[39:32] == 4 ? WRITE : READ;
                end
                WRITE: if (issue) state <= READ;
                READ:  if (issue) state <= WAIT_READ;
                WAIT_READ:
                if (rd_valid) begin
                    readback <= rd_data;
                    for (lane = 0; lane < 32; lane = lane + 1)
                    mismatch[lane] <= write_command && !mask[lane] && rd_data[lane*8+:8] != payload[lane*8+:8];
                    state <= CHECK;
                end
                CHECK: begin
                    failed <= |mismatch;
                    state <= FINISH;
                end
                FINISH: begin
                    response <= 0;
                    response[31:0] <= 32'h44445233;
                    response[63:32] <= seq;
                    response[95:64] <= {27'b0, failed, failed, calibrated, 1'b1, 1'b0};
                    response[127:96] <= failed ? 1 : 0;
                    response[159:128] <= failed ? address : 32'hffffffff;
                    response[191:160] <= 1;
                    response[223:192] <= write_command;
                    response[511:256] <= readback;
                    acknowledge <= request;
                    state <= IDLE;
                end
            endcase
            if (busy && state != FINISH && (!calibrated || watchdog == 32'd100000000)) begin
                failed <= 1;
                state <= FINISH;
            end
        end
    end

endmodule
