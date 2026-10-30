// Buffer two DDR commands so downstream ready does not feed straight back to the sender.
module command_buffer (
    input wire clk,
    input wire rst,
    input wire in_valid,
    output wire in_ready,
    input wire [2:0] in_cmd,
    input wire [28:0] in_addr,
    input wire [255:0] in_data,
    input wire [31:0] in_mask,
    input wire cmd_ready,
    input wire wr_ready,
    output wire cmd_en,
    output wire wr_en,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] data,
    output wire [31:0] mask
);

    reg [1:0] count = 0;
    reg head = 0, tail = 0;
    reg [319:0] slots[0:1];
    reg [319:0] captured;
    reg pending = 0;
    // Leave a slot for the command in the input register.
    always @(posedge clk) captured <= {in_cmd, in_addr, in_data, in_mask};
    assign {cmd, addr, data, mask} = slots[head];
    wire consume = count != 0 && cmd_ready && (cmd != 0 || wr_ready);
    wire push = pending;
    assign in_ready = count != 2 && !(count == 1 && pending);
    assign cmd_en = consume;
    assign wr_en = consume && cmd == 0;
    // Give each 32-bit word its own write enable to keep fanout local.
    genvar entry, word;

    generate
        for (entry = 0; entry < 2; entry = entry + 1) begin : entries
            for (word = 0; word < 10; word = word + 1) begin : words
                wire local_enable  /* synthesis syn_keep=1 */;
                LUT2 #(
                    .INIT(4'h8)
                ) gate (
                    .I0(push && !rst),
                    .I1(tail == entry),
                    .F (local_enable)
                );

                always @(posedge clk)
                    if (local_enable)
                        slots[entry][word*32+:32] <= captured[word*32+:32];
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            count <= 0;
            head <= 0;
            tail <= 0;
            pending <= 0;
        end else begin
            pending <= in_valid && in_ready;
            case ({
                push, consume
            })
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
            endcase
            if (push) tail <= ~tail;
            if (consume) head <= ~head;
        end
    end

endmodule
