// Decode streamed graph edges and hold the pipeline when a state tile stalls.
module edge_decoder #(
    parameter LANES=42
) (
    clk, rst, active, edge_left,
    edge_lane, stream_valid, stream_data, event_ready,
    edge_ready, edge_take, event_valid, event_row,
    event_lane, event_weight
);
    input clk;
    input rst;
    input active;
    input [13:0] edge_left;
    input [1:0] edge_lane;
    input stream_valid;
    input [255:0] stream_data;
    input event_ready;
    output edge_ready;
    output edge_take;
    output event_valid;
    output [12:0] event_row;
    output [6:0] event_lane;
    output signed [17:0] event_weight;

    localparam [23:0] ID_RECIPROCAL = (16777216 + LANES - 1) / LANES;
    reg target_valid = 0, product_valid = 0, event_valid = 0;
    reg [17:0] target_id, product_id;
    reg [41:0] target_product;
    wire [31:0] event_lane_value = {14'b0, product_id} - {14'b0, target_product[41:24]} * LANES;
    reg signed [17:0] target_weight, product_weight, event_weight;
    reg [12:0] event_row;
    reg [ 6:0] event_lane;
    wire edge_advance = !event_valid || event_ready;
    wire edge_ready = active && edge_left != 0 && edge_advance;
    wire edge_take = edge_ready && stream_valid;
    wire [63:0] edge_word = stream_data[edge_lane*64+:64];

    always @(posedge clk) begin
        if (rst || !active) begin
            target_valid <= 0;
            product_valid <= 0;
            event_valid <= 0;
        end else if (edge_advance) begin
            event_valid <= product_valid;
            if (product_valid) begin
                event_row <= target_product[36:24];
                event_lane <= event_lane_value[6:0];
                event_weight <= product_weight;
            end
            product_valid <= target_valid;
            if (target_valid) begin
                target_product <= target_id * ID_RECIPROCAL;
                product_id <= target_id;
                product_weight <= target_weight;
            end
            target_valid <= edge_take;
            if (edge_take) begin
                target_id <= edge_word[17:0];
                target_weight <= edge_word[35:18];
            end
        end
    end
endmodule
