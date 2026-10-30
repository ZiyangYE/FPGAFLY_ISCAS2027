// Read one neuron through a two-level mux outside the timed frame computation.
module state_sample #(
    parameter LANES=42
) (
    clk, rst, request, neuron,
    raw_result, raw_read, raw_row, done,
    value
);
    input clk;
    input rst;
    input request;
    input [17:0] neuron;
    input [LANES*24-1:0] raw_result;
    output raw_read;
    output [12:0] raw_row;
    output done;
    output [40:0] value;

    localparam IDLE=0, ADDRESS=1, READ=2, WAIT_RAM=3, CAPTURE=4, MERGE=5, REPLY=6;
    localparam [23:0] RECIPROCAL = (16777216 + LANES - 1) / LANES;
    localparam GROUPS = (LANES + 7) / 8;
    reg [2:0] state = IDLE;
    reg [17:0] id;
    reg [41:0] product;
    reg [12:0] raw_row;
    reg [6:0] lane;
    wire [31:0] lane_value = {14'b0, id} - {14'b0, product[41:24]} * LANES;
    wire [GROUPS*192-1:0] padded = {{((GROUPS*8-LANES)*24){1'b0}}, raw_result};
    reg [GROUPS*24-1:0] groups;
    reg [23:0] code;
    wire signed [17:0] u, g;
    wire [4:0] refractory;
    assign raw_read = state == READ;
    assign done = state == REPLY;
    assign value = {refractory, g, u};
    state_decode decode (.code(code), .u(u), .g(g), .refractory(refractory));

    genvar group;
    generate
        for (group=0; group<GROUPS; group=group+1) begin : select_group
            wire [191:0] row = padded[group*192+:192];
            always @(posedge clk)
                if (state == CAPTURE) groups[group*24+:24] <= row[lane[2:0]*24+:24];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else case (state)
            IDLE: if (request) begin
                id <= neuron;
                product <= neuron * RECIPROCAL;
                state <= ADDRESS;
            end
            ADDRESS: begin
                raw_row <= product[36:24];
                lane <= lane_value[6:0];
                state <= READ;
            end
            READ: state <= WAIT_RAM;
            WAIT_RAM: state <= CAPTURE;
            CAPTURE: state <= MERGE;
            MERGE: begin
                code <= groups[lane[6:3]*24+:24];
                state <= REPLY;
            end
            REPLY: state <= IDLE;
        endcase
    end
endmodule
