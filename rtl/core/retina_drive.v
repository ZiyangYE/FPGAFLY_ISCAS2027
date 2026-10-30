// Generate one row of retinal drive at a time; stall with the state array.
module retina_drive #(
    parameter N=166700, LANES=42, BIAS1_END=3555, RETINA_BEGIN=5327, RETINA_COUNT=3335
) (
    clk, rst, start, frame_step,
    stream_valid, stream_data, dense_ready, dense_valid,
    generate_row, drives, drive_ready, prepare_input, input_busy
);
    input clk;
    input rst;
    input start;
    input [11:0] frame_step;
    input stream_valid;
    input [255:0] stream_data;
    input dense_ready;
    output dense_valid;
    output [12:0] generate_row;
    output [LANES*18-1:0] drives;
    output drive_ready, input_busy;
    output reg prepare_input = 0;

    localparam ROWS = (N + LANES - 1) / LANES;
    localparam RFIRST = RETINA_BEGIN / LANES;
    localparam RLAST = (RETINA_BEGIN + RETINA_COUNT - 1) / LANES;
    localparam PULSE_LINES = (LANES + 5) / 6;
    reg dense_active = 0;
    reg [12:0] generate_row = 0;
    localparam RETINA_ROWS = RLAST - RFIRST + 1;
    localparam INPUT_LINES = RETINA_ROWS * PULSE_LINES;
    (* syn_ramstyle="registers" *) reg [LANES-1:0] pulse_rows[0:RETINA_ROWS-1];
    reg [LANES-1:0] row_pulses;
    reg retinal_row = RFIRST == 0;
    reg row_ready = 0, preparing = 0;
    reg [9:0] records_read = 0;
    reg [6:0] write_row = 0, prepared_rows = 0;
    reg [4:0] write_block = 0;
    reg [9:0] pulse_step = 0;
    reg [6:0] retinal_index = 0;
    reg input_active = 0, next_input = 0;
    reg begin_input = 0;
    wire drive_take = drive_ready && stream_valid;
    wire pulse_valid;
    wire [5:0] pixel_pulses;

    assign dense_valid = dense_active &&
        (!retinal_row || !input_active || row_ready);
    assign drive_ready = preparing && records_read < INPUT_LINES;
    assign input_busy = preparing || begin_input || prepare_input;

    always @(posedge clk) begin
        begin_input <= !rst && (start && frame_step == 0 || prepare_input);
        if (start) pulse_step <= 0;
        else if (prepare_input) pulse_step <= frame_step[9:0] + 10'd1;
        prepare_input <= !rst && dense_valid && dense_ready &&
            generate_row == RLAST && next_input;
        if (rst) begin
            input_active <= 0;
            next_input <= 0;
            retinal_index <= 0;
        end else if (start) begin
            input_active <= frame_step < 1000;
            next_input <= frame_step < 999;
            retinal_index <= 0;
        end else if (dense_valid && dense_ready && retinal_row)
            retinal_index <= retinal_index + 1'b1;
    end

    // Prepare the next step after its predecessor has consumed all retinal rows.
    retina_pulses pulse_conversion (
        .clk(clk), .rst(rst || begin_input), .valid(drive_take),
        .block_index(5'b0), .step(pulse_step), .records(stream_data),
        .busy(), .out_valid(pulse_valid), .out_block(), .pulses(pixel_pulses)
    );

    always @(posedge clk) begin
        if (rst) begin
            preparing <= 0;
            prepared_rows <= 0;
            records_read <= 0;
            write_row <= 0;
            write_block <= 0;
        end else if (begin_input) begin
            preparing <= 1;
            prepared_rows <= 0;
            records_read <= 0;
            write_row <= 0;
            write_block <= 0;
        end else begin
            if (drive_take) records_read <= records_read + 1'b1;
            if (pulse_valid) begin
                if (write_block == PULSE_LINES - 1) begin
                    write_block <= 0;
                    write_row <= write_row + 1'b1;
                    prepared_rows <= prepared_rows + 1'b1;
                    if (write_row == RETINA_ROWS - 1) preparing <= 0;
                end else write_block <= write_block + 1'b1;
            end
        end
        if (rst || start || dense_valid && dense_ready) row_ready <= 0;
        else if (retinal_row && input_active && prepared_rows > retinal_index) begin
            row_pulses <= pulse_rows[retinal_index];
            row_ready <= 1;
        end
    end

    genvar lane;

    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : drive_lanes
            // Neuron ID = row * LANES + lane. Boundary lanes are fixed at elaboration.
            wire under_n = generate_row < N / LANES
                || (generate_row == N / LANES && lane < N % LANES);
            wire under_bias1 = generate_row < BIAS1_END / LANES
                || (generate_row == BIAS1_END / LANES && lane < BIAS1_END % LANES);
            wire under_retina = generate_row < RETINA_BEGIN / LANES
                || (generate_row == RETINA_BEGIN / LANES && lane < RETINA_BEGIN % LANES);
            wire under_retina_end = generate_row < (RETINA_BEGIN + RETINA_COUNT) / LANES
                || (generate_row == (RETINA_BEGIN + RETINA_COUNT) / LANES
                    && lane < (RETINA_BEGIN + RETINA_COUNT) % LANES);
            assign drives[lane*18+:18] = !under_n ? 18'd0 :
                under_bias1 ? 18'd1024 :
                under_retina ? 18'd1088 :
                under_retina_end && input_active && row_pulses[lane] ? 18'd20480 : 18'd0;

            always @(posedge clk)
                if (pulse_valid && write_block == lane / 6)
                    pulse_rows[write_row][lane] <= pixel_pulses[lane%6];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            dense_active <= 0;
            generate_row <= 0;
            retinal_row <= RFIRST == 0;
        end else if (start) begin
            dense_active <= 1;
            generate_row <= 0;
            retinal_row <= RFIRST == 0;
        end else begin
            if (dense_valid && dense_ready) begin
                generate_row <= generate_row + 1'b1;
                retinal_row <= (RFIRST == 0 || generate_row >= RFIRST - 1)
                    && generate_row < RLAST;
                if (generate_row == ROWS - 1) dense_active <= 0;
            end
        end
    end
endmodule
