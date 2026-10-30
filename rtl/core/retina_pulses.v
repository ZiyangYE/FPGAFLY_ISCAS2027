// Six retinal records per clock; white emits 100 pulses in 1000 steps.
// Records contain intensity[7:0], phase[17:8] and onset[23:18].
module retina_pulses (
    input wire clk,
    input wire rst,
    input wire valid,
    input wire [4:0] block_index,
    input wire [9:0] step,
    input wire [255:0] records,
    output wire busy,
    output wire out_valid,
    output wire [4:0] out_block,
    output reg [5:0] pulses
);
    reg [9:0] pending = 0;
    reg [4:0] tags[0:9];
    integer stage;
    assign busy = |pending;
    assign out_valid = pending[9];
    assign out_block = tags[9];

    always @(posedge clk) begin
        if (rst) pending <= 0;
        else pending <= {pending[8:0], valid};
        tags[0] <= block_index;
        for (stage = 1; stage < 10; stage = stage + 1)
            tags[stage] <= tags[stage-1];
    end

    genvar lane;
    generate
        for (lane = 0; lane < 6; lane = lane + 1) begin : channels
            reg [17:0] product, phase_sum, remainder64;
            reg [16:0] remainder32;
            reg [15:0] remainder16;
            reg [14:0] remainder8;
            reg [13:0] remainder4;
            reg [12:0] remainder2;
            reg [11:0] remainder1, initial_phase;
            reg [7:0] pixel[0:8];
            reg [8:0] enabled;
            integer delay;
            wire [11:0] next_phase = remainder1 + {4'b0, pixel[8]};

            always @(posedge clk) begin
                product <= records[lane*32+:8] * step;
                initial_phase <= records[lane*32+8+:12];
                phase_sum <= product + {6'b0, initial_phase};
                pixel[0] <= records[lane*32+:8];
                for (delay = 1; delay < 9; delay = delay + 1)
                    pixel[delay] <= pixel[delay-1];
                enabled <= {enabled[7:0], step >= {4'b0, records[lane*32+20+:6]}};

                // Remove descending multiples of 2550, one short stage at a time.
                remainder64 <= phase_sum >= 18'd163200
                    ? phase_sum - 18'd163200 : phase_sum;
                remainder32 <= remainder64 >= 18'd81600
                    ? remainder64 - 18'd81600 : remainder64;
                remainder16 <= remainder32 >= 17'd40800
                    ? remainder32 - 17'd40800 : remainder32;
                remainder8 <= remainder16 >= 16'd20400
                    ? remainder16 - 16'd20400 : remainder16;
                remainder4 <= remainder8 >= 15'd10200
                    ? remainder8 - 15'd10200 : remainder8;
                remainder2 <= remainder4 >= 14'd5100
                    ? remainder4 - 14'd5100 : remainder4;
                remainder1 <= remainder2 >= 13'd2550
                    ? remainder2 - 13'd2550 : remainder2;
                pulses[lane] <= enabled[8] && next_phase >= 2550;
            end
        end
    endgenerate
endmodule
