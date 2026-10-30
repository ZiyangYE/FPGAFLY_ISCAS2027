// Op 16 streams USER2 data to DDR, then reads back the last write before replying.
module memory_loader (
    input wire clk,
    input wire rst,
    input wire calibrated,
    input wire request,
    input wire [511:0] packet,
    output reg acknowledge = 0,
    output reg [511:0] response = 0,
    output wire busy,
    input wire bulk_request,
    input wire [255:0] bulk_data,
    input wire bulk_overrun,
    output reg bulk_acknowledge = 0,
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
    localparam FENCE = 5;
    localparam WAIT_FENCE = 6;
    localparam DONE = 7;
    localparam CHECK1 = 8;
    localparam CHECK2 = 9;
    reg [3:0] state = IDLE;
    (* syn_preserve=1 *) reg [2:0] bulk_sync = 0, error_sync = 0;
    reg [31:0] seq, completed, watchdog;
    reg [31:0] last_index, current_address, last_address;
    reg [63:0] cycles;
    reg [255:0] buffer, last_data;
    reg failed;
    reg [7:0] mismatch_words;
    integer lane;
    wire write_fire = state == WRITE && bulk_sync[2] != bulk_acknowledge && cmd_ready && wr_ready;
    wire read_fire = state == FENCE && cmd_ready;
    assign busy = state != IDLE;
    assign cmd_en = write_fire || read_fire;
    assign cmd = state == WRITE ? 3'b000 : 3'b001;
    wire [31:0] byte_address = state == FENCE ? last_address : current_address;
    assign addr = {1'b0, byte_address[29:2]};
    assign wr_en = write_fire;
    assign wr_data = bulk_data;
    assign wr_mask = 0;

    always @(posedge clk) begin
        bulk_sync <= {bulk_sync[1:0], bulk_request};
        error_sync <= {error_sync[1:0], bulk_overrun};
        if (rst) begin
            state <= IDLE;
            acknowledge <= request;
            bulk_acknowledge <= bulk_sync[2];
            response <= 0;
        end else begin
            if (busy) begin
                cycles <= cycles + 1;
                watchdog <= watchdog + 1;
                if (cmd_en || rd_valid) watchdog <= 0;
            end
            case (state)
                IDLE:
                if (request != acknowledge) begin
                    seq <= packet[63:32];
                    last_index <= packet[127:96] - 1'b1;
                    current_address <= packet[95:64];
                    completed <= 0;
                    cycles <= 0;
                    watchdog <= 0;
                    failed <= 0;
                    bulk_acknowledge <= bulk_sync[2];
                    if (!calibrated || packet[31:0] != 32'h44445233 || packet[68:64] != 0 ||
                   packet[127:96] == 0 || packet[127:96]>32'h2000000 ||
                   ({1'b0,packet[95:64]}+({1'b0,packet[127:96]}<<5))>33'h40000000 ||
                   packet[39:32] != 16) begin
                        failed <= 1;
                        state <= DONE;
                    end else state <= WRITE;
                end
                WRITE:
                if (write_fire) begin
                    bulk_acknowledge <= bulk_sync[2];
                    last_data <= bulk_data;
                    completed <= completed + 1;
                    last_address <= current_address;
                    current_address <= current_address + 32;
                    if (completed == last_index) state <= FENCE;
                end
                FENCE: if (read_fire) state <= WAIT_FENCE;
                WAIT_FENCE:
                if (rd_valid) begin
                    buffer <= rd_data;
                    state <= CHECK1;
                end
                CHECK1: begin
                    for (lane = 0; lane < 8; lane = lane + 1)
                    mismatch_words[lane] <= buffer[lane*32+:32] != last_data[lane*32+:32];
                    state <= CHECK2;
                end
                CHECK2: begin
                    failed <= failed || (|mismatch_words);
                    state <= DONE;
                end
                DONE: begin
                    response <= 0;
                    response[31:0] <= 32'h44445233;
                    response[63:32] <= seq;
                    response[95:64] <= {27'b0, failed, failed, calibrated, 1'b1, 1'b0};
                    response[127:96] <= failed ? 1 : 0;
                    response[223:192] <= seq[7:0] == 16 ? completed : 0;
                    response[351:288] <= cycles;
                    response[511:480] <= 100000000;
                    acknowledge <= request;
                    state <= IDLE;
                end
            endcase
            if (busy && state != DONE && (!calibrated || watchdog == 32'd100000000 ||
                (state == WRITE && error_sync[2]))) begin
                failed <= 1;
                state <= DONE;
            end
        end
    end

endmodule
