// Select firing neurons from one buffered row, sixteen lanes at a time.
module spike_cursor #(
    parameter N=166700, LANES=42
) (
    input clk, load, select_group, select_lane, consume,
    input [LANES+11:0] row_data,
    output empty,
    output reg [17:0] source,
    output reg in_range
);
    reg [12:0] row;
    reg [LANES-1:0] mask;
    reg [6:0] lane;
    reg [3:0] group;
    wire [31:0] neuron = row * LANES + lane;
    wire [255:0] padded = {{(256-LANES){1'b0}}, mask};
    wire [15:0] groups;
    wire [3:0] first_group, first_lane;
    assign empty = mask == 0;

    priority_encoder group_select (groups, first_group);
    priority_encoder lane_select (padded[group*16+:16], first_lane);
    genvar i;
    generate
        for (i=0; i<16; i=i+1) begin : group_flags
            assign groups[i] = |padded[i*16+:16];
        end
    endgenerate

    always @(posedge clk) begin
        if (load) {row, mask} <= {1'b0, row_data};
        if (select_group && !empty) group <= first_group;
        if (select_lane) lane <= {group[2:0], first_lane};
        if (consume) begin
            source <= neuron[17:0];
            mask[lane] <= 0;
            in_range <= row < N/LANES || (row == N/LANES && lane < N%LANES);
        end
    end
endmodule
