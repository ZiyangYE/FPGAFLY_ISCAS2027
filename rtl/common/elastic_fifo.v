// Use queue flags for backpressure; data registers need neither reset nor a shared enable.
module elastic_fifo (
    clk,
    rst,
    in_valid,
    in_ready,
    in_data,
    out_valid,
    out_ready,
    out_data
);

    parameter  WIDTH = 19, AW = 1;
    localparam DEPTH = 1 << AW;
    input clk, rst, in_valid, out_ready;
    input [WIDTH-1:0] in_data;
    output in_ready, out_valid;
    output [WIDTH-1:0] out_data;
    reg [AW-1:0] head = 0, tail = 0;
    reg [AW:0] used = 0;
    reg has_space = 1, has_data = 0;
    (* syn_ramstyle="registers" *) reg [WIDTH-1:0] data[0:DEPTH-1];
    wire push = in_valid && in_ready;
    wire pop = out_valid && out_ready;
    assign in_ready = has_space && !rst;
    assign out_valid = has_data && !rst;
    assign out_data = data[head];

    always @(posedge clk) begin
        if (rst) begin
            head <= 0;
            tail <= 0;
            used <= 0;
            has_space <= 1;
            has_data <= 0;
        end else begin
            if (push) begin
                data[tail] <= in_data;
                tail <= tail + 1'b1;
            end
            if (pop) head <= head + 1'b1;
            case ({
                push, pop
            })
                2'b10: begin
                    used <= used + 1'b1;
                    has_space <= used < DEPTH - 1;
                    has_data <= 1;
                end
                2'b01: begin
                    used <= used - 1'b1;
                    has_space <= 1;
                    has_data <= used > 1;
                end
            endcase
        end
    end

endmodule
