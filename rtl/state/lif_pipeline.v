// Reset clears valid flags. Data registers may keep updating while reset is asserted.
(* syn_srlstyle="registers" *)
module lif_pipeline #(
    parameter TAG_WIDTH = 18
) (
    input wire clk,
    input wire rst,
    input wire valid,
    input wire [TAG_WIDTH-1:0] tag,
    input wire signed [17:0] u,
    input wire signed [17:0] g,
    input wire signed [17:0] drive,
    input wire [4:0] refractory,
    output wire ready,
    output wire out_valid,
    input wire out_ready,
    output reg [TAG_WIDTH-1:0] out_tag,
    output reg signed [17:0] next_u,
    output reg signed [17:0] next_g,
    output reg [4:0] next_refractory,
    output reg fire,
    output reg clipped,
    output reg state_wide
);

    (* syn_preserve=1 *) reg [4:0] valids = 0;
    reg [4*TAG_WIDTH-1:0] tags;
    reg [53:0] us, gs;
    reg [19:0] refs;
    reg signed [18:0] delta0;
    reg signed [29:0] prod_u1, prod_g1;
    reg signed [30:0] decay_g1, num_u2, num_g2;
    reg signed [18:0] un3, gn3;
    wire signed [30:0] product_u = delta0 * 12'sd1307;
    wire signed [30:0] product_g = $signed(gs[0+:18]) * 13'sd2588;
    wire signed [31:0] product_decay = $signed(gs[0+:18]) * (-14'sd5191);
    wire signed [31:0] sum_u = {{2{prod_u1[29]}},prod_u1}+{{2{prod_g1[29]}},prod_g1}+32'sd131072;
    wire signed [31:0] sum_g = {decay_g1[30], decay_g1} + 32'sd131072;
    wire signed [30:0] updated_u = $signed(us[36+:18]) + (num_u2 >>> 18);
    wire signed [30:0] updated_g = $signed(gs[36+:18]) + (num_g2 >>> 18);
    wire advance = !valids[4] || out_ready;
    wire [7:0] enables;
    assign ready = advance;
    assign out_valid = valids[4];
    genvar group_index, k;

    generate
        for (group_index = 0; group_index < 8; group_index = group_index + 1) begin : control
            wire local_enable  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) gate (
                .I0(advance),
                .I1(1'b1),
                .F (local_enable)
            );

            assign enables[group_index] = local_enable;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) valids <= 0;
        else if (advance) valids <= {valids[3:0], valid};
        if (enables[0]) begin
            tags[0+:TAG_WIDTH] <= tag;
            us[0+:18] <= u;
            gs[0+:18] <= g;
            refs[0+:5] <= refractory;
            delta0 <= $signed({drive[17], drive}) - $signed({u[17], u});
        end
    end

    generate
        for (k = 1; k < 4; k = k + 1) begin : delays

            always @(posedge clk)
                if (enables[k]) begin
                    tags[k*TAG_WIDTH+:TAG_WIDTH] <= tags[(k-1)*TAG_WIDTH+:TAG_WIDTH];
                    refs[k*5+:5] <= refs[(k-1)*5+:5];
                end
            if (k < 3) begin : states

                always @(posedge clk)
                    if (enables[k]) begin
                        us[k*18+:18] <= us[(k-1)*18+:18];
                        gs[k*18+:18] <= gs[(k-1)*18+:18];
                    end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (enables[4]) begin
            prod_u1 <= product_u[29:0];
            prod_g1 <= product_g[29:0];
            decay_g1 <= product_decay[30:0];
        end
        if (enables[5]) begin
            num_u2 <= sum_u[30:0];
            num_g2 <= sum_g[30:0];
        end
        if (enables[6]) begin
            if (refs[10+:5] > 1) begin
                un3 <= $signed(us[36+:18]);
                gn3 <= $signed(gs[36+:18]);
            end else begin
                un3 <= updated_u[18:0];
                gn3 <= updated_g[18:0];
            end
        end
        if (enables[7]) begin
            out_tag <= tags[3*TAG_WIDTH+:TAG_WIDTH];
            next_refractory <= 0;
            fire <= 0;
            clipped <= 0;
            state_wide <= 0;
            if (refs[15+:5] > 1) begin
                next_u <= un3[17:0];
                next_g <= gn3[17:0];
                next_refractory <= refs[15+:5] - 1'b1;
                state_wide <= un3 != 0 || gn3 != 0 || refs[15+:5] > 23;
            end else if (un3 > 32'sd896) begin
                next_u <= 0;
                next_g <= 0;
                next_refractory <= 22;
                fire <= 1;
            end else begin
                state_wide <= un3 < -19'sd4096 || gn3 < -19'sd1024 || gn3 > 19'sd1023;
                if (un3 < -32'sd131072) begin
                    next_u <= -18'sd131072;
                    clipped <= 1;
                end else next_u <= un3[17:0];
                next_g <= gn3[17:0];
            end
        end
    end

endmodule
