// Decode, integrate and encode each lane locally.
module row_integrator #(
    parameter LANES = 6
) (
    input clk,
    input rst,
    input valid,
    output ready,
    input [12:0] row,
    input [LANES*24-1:0] codes,
    input [LANES*18-1:0] drive,
    output out_valid,
    input out_ready,
    output reg [12:0] out_row,
    output [LANES*24-1:0] out_codes,
    output [LANES-1:0] fire,
    output failed
);

    reg  full = 0;
    wire advance = !full || out_ready;
    wire [LANES-1:0] lane_ready, lane_valid;
    wire [12:0] pipeline_row;
    reg decoded_valid = 0;
    reg [12:0] decoded_row;
    wire decode_advance = !decoded_valid || lane_ready[0];
    assign ready = decode_advance;
    assign out_valid = full;
    assign failed = 0;

    always @(posedge clk) begin
        if (rst) decoded_valid <= 0;
        else if (decode_advance) decoded_valid <= valid;
        if (decode_advance) decoded_row <= row;
        if (rst) full <= 0;
        else if (advance) full <= lane_valid[0];
        if (advance) out_row <= pipeline_row;
    end
    genvar lane;

    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : lanes
            wire signed [17:0] u, g, next_u, next_g;
            wire [4:0] refractory, next_ref;
            wire [12:0] tag;
            wire fired;
            wire [23:0] encoded;
            reg [23:0] saved_code;
            reg saved_fire;
            reg signed [17:0] decoded_u, decoded_g, decoded_drive;
            reg [4:0] decoded_ref;
            wire decode_capture  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) decode_gate (
                .I0(decode_advance),
                .I1(1'b1),
                .F (decode_capture)
            );

            always @(posedge clk)
                if (decode_capture) begin
                    decoded_u <= u;
                    decoded_g <= g;
                    decoded_drive <= drive[lane*18+:18];
                    decoded_ref <= refractory;
                end
            wire capture  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) gate (
                .I0(advance),
                .I1(1'b1),
                .F (capture)
            );

            state_decode decode (
                .code(codes[lane*24+:24]),
                .u(u),
                .g(g),
                .refractory(refractory)
            );

            lif_pipeline #(
                .TAG_WIDTH(13)
            ) integrate (
                .clk(clk),
                .rst(rst),
                .valid(decoded_valid),
                .tag(decoded_row),
                .u(decoded_u),
                .g(decoded_g),
                .drive(decoded_drive),
                .refractory(decoded_ref),
                .ready(lane_ready[lane]),
                .out_valid(lane_valid[lane]),
                .out_ready(advance),
                .out_tag(tag),
                .next_u(next_u),
                .next_g(next_g),
                .next_refractory(next_ref),
                .fire(fired),
                .clipped(),
                .state_wide()
            );

            state_encode encode (
                .u(next_u),
                .g(next_g),
                .refractory(next_ref),
                .code(encoded)
            );

            always @(posedge clk)
                if (capture) begin
                    saved_code <= encoded;
                    saved_fire <= fired;
                end
            assign out_codes[lane*24+:24] = saved_code;
            assign fire[lane] = saved_fire;
            if (lane == 0) assign pipeline_row = tag;
            // synthesis translate_off
            always @(negedge clk)
                if (!rst) begin
                    if (lane_ready[lane] !== lane_ready[0] || lane_valid[lane] !== lane_valid[0])
                        $fatal(1, "Approximate integration lanes diverged");
                end
            // synthesis translate_on
        end
    endgenerate

endmodule
