// RAM simulation models for the 9-bit and 18-bit modes used by the design.
module SDPX9B #(
    parameter BIT_WIDTH_0=18,BIT_WIDTH_1=18,READ_MODE=0,BLK_SEL_0=0,BLK_SEL_1=0
)(
    output reg [35:0] DO,input wire [35:0] DI,
    input wire [2:0] BLKSELA,BLKSELB,input wire [13:0] ADA,ADB,
    input wire CLKA,CLKB,CEA,CEB,OCE,RESET
);
    initial begin
        if(BIT_WIDTH_0!=BIT_WIDTH_1 || (BIT_WIDTH_0!=9 && BIT_WIDTH_0!=18) || READ_MODE!=0)
            $fatal(1,"unsupported RAM mode");
    end
    generate if(BIT_WIDTH_0==9)begin:narrow
        reg [8:0] mem[0:2047];
        always @(posedge CLKA)if(CEA && BLKSELA==BLK_SEL_0)mem[ADA[13:3]]<=DI[8:0];
        always @(posedge CLKB)if(CEB && BLKSELB==BLK_SEL_1)DO<={27'b0,mem[ADB[13:3]]};
    end else begin:wide
        reg [17:0] mem[0:1023];
        always @(posedge CLKA)if(CEA && BLKSELA==BLK_SEL_0)begin
            if(ADA[0])mem[ADA[13:4]][8:0]<=DI[8:0];
            if(ADA[1])mem[ADA[13:4]][17:9]<=DI[17:9];
        end
        always @(posedge CLKB)if(CEB && BLKSELB==BLK_SEL_1)DO<={18'b0,mem[ADB[13:4]]};
    end endgenerate
endmodule
module GSR(input wire GSRI);
endmodule

module LUT2 #(parameter INIT=4'h0)(output wire F,input wire I0,I1);
    assign F=INIT[{I1,I0}];
endmodule

module LUT3 #(parameter INIT=8'h00)(output wire F,input wire I0,I1,I2);
    wire [3:0] half=I2 ? INIT[7:4] : INIT[3:0];
    wire [1:0] pair=I1 ? half[3:2] : half[1:0];
    assign F=I0 ? pair[1] : pair[0];
endmodule

module DFFE #(parameter INIT=1'b0)(output reg Q=INIT,input wire D,CLK,CE);
    always @(posedge CLK)if(CE)Q<=D;
endmodule
