// Values in the normal range are stored exactly. Out-of-range values use two signed 11-bit
// fields with a scale of eight, identified by a reserved tag.
module state_encode (
    input signed [17:0] u,
    input signed [17:0] g,
    input [4:0] refractory,
    output reg [23:0] code
);

    wire signed [18:0] uround = $signed({u[17], u}) + 19'sd4;
    wire signed [18:0] ground = $signed({g[17], g}) + 19'sd4;
    wire signed [18:0] uq = uround >>> 3, gq = ground >>> 3;
    wire [10:0] uc = uq < -19'sd1024 ? 11'h400 : uq > 19'sd1023 ? 11'h3ff : uq[10:0];
    wire [10:0] gc = gq < -19'sd1024 ? 11'h400 : gq > 19'sd1023 ? 11'h3ff : gq[10:0];

    always @* begin
        if (refractory != 0) code = {11'b0, 13'd896 + {8'b0, refractory}};
        else if (u >= -18'sd4096 && u <= 18'sd896 && g >= -18'sd1024 && g <= 18'sd1023)
            code = {g[10:0], u[12:0]};
        else code = {gc, 2'b01, uc};
    end

endmodule

module state_decode (
    input [23:0] code,
    output reg signed [17:0] u,
    output reg signed [17:0] g,
    output reg [4:0] refractory
);

    always @* begin
        refractory = 0;
        if (code[12:11] == 2'b01) begin
            u = {{4{code[10]}}, code[10:0], 3'b0};
            g = {{4{code[23]}}, code[23:13], 3'b0};
        end else begin
            u = {{5{code[12]}}, code[12:0]};
            g = {{7{code[23]}}, code[23:13]};
            if (code[23:5] == 19'd28 && code[4:0] != 0 && code[4:0] <= 5'd22) begin
                u = 0;
                g = 0;
                refractory = code[4:0];
            end
        end
    end

endmodule
