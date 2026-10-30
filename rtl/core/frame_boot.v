// Load the starting neuron state, retinal records, readout bias and delay queues.
module frame_boot #(
    parameter N=166700, LANES=42, RETINA_BEGIN=5327, RETINA_COUNT=3335
) (
    input clk, rst, start, resume,
    input direct_ready, direct_response,
    input [255:0] rd_data,
    input stream_valid,
    input [255:0] stream_data,
    input [17:0] pixel_value,
    output done, direct_valid, direct_write,
    output [31:0] direct_address,
    output [255:0] direct_data,
    output stream_start,
    output [31:0] stream_base,
    output [23:0] stream_lines,
    output stream_take, pixel_write,
    output reg pixel_mode = 0,
    output [9:0] pixel_write_address,
    output [17:0] pixel_write_data,
    output pixel_read,
    output [9:0] pixel_address,
    output raw_write,
    output [12:0] raw_address,
    output [LANES*24-1:0] raw_data,
    output bias_valid,
    output [1:0] bias_page,
    output [255:0] bias_data,
    output queue_valid,
    output [4:0] queue_slot,
    output [17:0] queue_count,
    output reg [21:0] pending_events = 0,
    output reg [17:0] queue_peak = 0
);

    localparam RFIRST = RETINA_BEGIN / LANES;
    localparam RLAST = (RETINA_BEGIN + RETINA_COUNT - 1) / LANES;
    localparam PULSE_LINES = (LANES + 5) / 6;
    localparam PULSE_MAPLINES = (RLAST - RFIRST + 1) * PULSE_LINES;
    localparam WARM_QUEUE=32'h1a000000;
    localparam INPUT_IMAGE=32'h10700000, READOUT_BIAS=32'h10610000;
    localparam RETINA_MAP=32'h10980000, RETINA_DRIVES=32'h10990000;
    localparam IDLE=0, WARM_LOAD=1, MEMORY_REQUEST=2, MEMORY_RESPONSE=3;
    localparam IMAGE_READ=4, IMAGE_LOAD=5, IMAGE_UNPACK=6, BIAS_READ=7;
    localparam BIAS_LOAD=8, MAP_START=9, MAP_GET=10, MAP_PIXEL=11;
    localparam MAP_LUT=12, MAP_PACK=13, MAP_WRITE=14, MAP_NEXT=15;
    localparam WARM_QUEUE_HEADER=16, WARM_QUEUE_COUNT=17, WARM_QUEUE_READ=18, WARM_QUEUE_COPY=19;
    localparam WARM_QUEUE_NEXT=20, DONE=21;
    localparam PHASE_BEGIN=22, PHASE_WAIT=23, MAP_PHASE_READ=24, MAP_PHASE_LOAD=25;
    reg [4:0] state = IDLE, return_state;
    reg bus_write;
    reg [31:0] bus_address;
    reg [255:0] bus_data, bus_result;
    reg bus_count_zero = 1;
    reg prepare_start = 0;
    reg [31:0] prepare_base;
    reg [23:0] prepare_lines;
    reg [15:0] index = 0;
    reg [4:0] image_byte = 0;
    reg [5:0] onset;
    reg [7:0] current_gray;
    reg [9:0] map_pixel_address;
    reg [11:0] current_phase;
    reg [2:0] map_word = 0;
    reg [255:0] drive_line = 0;
    reg [4:0] slot = 0;
    reg [17:0] warm_count;
    reg [31:0] warm_offset;
    reg [15:0] warm_last_line;
    reg image_index_last, bias_index_last, map_index_last, warm_index_last;
    wire [18:0] warm_lines = ({1'b0, bus_result[17:0]} + 19'd3) >> 2;
    wire [6:0] warm_slot_scaled = {2'b0, slot} + {1'b0, slot, 1'b0};
    wire [31:0] warm_queue_address = {4'h2, warm_slot_scaled, index, 5'b0};
    wire neurons_done, neurons_start, neurons_take;
    wire [31:0] neurons_base;
    wire [23:0] neurons_lines;
    neuron_loader #(.N(N), .LANES(LANES)) neurons (
        .clk(clk), .rst(rst), .start(start && !resume), .done(neurons_done),
        .stream_valid(stream_valid), .stream_data(stream_data),
        .stream_start(neurons_start), .stream_base(neurons_base),
        .stream_lines(neurons_lines), .stream_take(neurons_take),
        .raw_write(raw_write), .raw_address(raw_address), .raw_data(raw_data)
    );
    assign stream_start = neurons_start || prepare_start;
    assign stream_base = state == WARM_LOAD ? neurons_base : prepare_base;
    assign stream_lines = state == WARM_LOAD ? neurons_lines : prepare_lines;

    assign direct_valid = state == MEMORY_REQUEST;
    assign direct_write = bus_write;
    assign direct_address = bus_address;
    assign direct_data = bus_data;
    assign done = state == DONE;
    wire phase_active = state == PHASE_BEGIN || state == PHASE_WAIT;
    wire phase_read, phase_write, phase_done;
    wire [9:0] phase_address;
    wire [17:0] phase_data;
    input_phases phases (
        .clk(clk), .rst(rst), .start(state == PHASE_BEGIN), .resume(resume),
        .read_data(pixel_value), .read_enable(phase_read), .write_enable(phase_write),
        .address(phase_address), .write_data(phase_data), .done(phase_done)
    );
    assign pixel_address = phase_active ? phase_address : map_pixel_address;
    assign pixel_write = phase_active ? phase_write : state == IMAGE_UNPACK;
    assign pixel_write_address = phase_active ? phase_address : {index[4:0], image_byte};
    assign pixel_write_data = phase_active ? phase_data : {10'b0, bus_result[image_byte*8+:8]};
    assign pixel_read = phase_active ? phase_read : state == MAP_PIXEL || state == MAP_PHASE_READ;
    assign bias_valid = state == BIAS_LOAD;
    assign bias_page = index[1:0];
    assign bias_data = bus_result;
    assign queue_valid = state == WARM_QUEUE_COUNT;
    assign queue_slot = slot;
    assign queue_count = bus_result[17:0];
    assign stream_take = neurons_take
        || state == MAP_PACK && map_word == 5 || state == WARM_QUEUE_COPY;

    always @(posedge clk) begin
        image_index_last <= index == 7;
        bias_index_last <= index == 2;
        map_index_last <= index == PULSE_MAPLINES - 1;
        warm_index_last <= index == warm_last_line;
        if (rst || start) pixel_mode <= 0;
        else if (state == PHASE_BEGIN) pixel_mode <= 1;
        else if (state == WARM_QUEUE_HEADER || state == DONE) pixel_mode <= 0;
    end

    genvar word_index;
    generate
        for (word_index=0; word_index<8; word_index=word_index+1) begin : result_words
            wire capture /* synthesis syn_keep=1 */;
            assign capture = !rst && (state == MEMORY_RESPONSE && direct_response);
            always @(posedge clk)
                if (capture) bus_result[word_index*32+:32] <= rd_data[word_index*32+:32];
        end
    endgenerate

    always @(posedge clk) begin
        prepare_start <= 0;
        if (rst) state <= IDLE;
        else if (start) begin
            pending_events <= 0;
            queue_peak <= 0;
            state <= resume ? PHASE_BEGIN : WARM_LOAD;
        end else case (state)
            WARM_LOAD: if (neurons_done) state <= PHASE_BEGIN;

            PHASE_BEGIN: state <= PHASE_WAIT;
            PHASE_WAIT: if (phase_done) begin
                index <= 0;
                state <= IMAGE_READ;
            end

            MEMORY_REQUEST: if (direct_ready) state <= bus_write ? return_state : MEMORY_RESPONSE;

            MEMORY_RESPONSE:
                if (direct_response) begin
                    bus_count_zero <= rd_data[31:0] == 0;
                    state <= return_state;
                end

            IMAGE_READ: begin
                bus_address <= (INPUT_IMAGE + (index << 5)) & 32'hffffffe0;
                bus_write <= 0;
                return_state <= IMAGE_LOAD;
                state <= MEMORY_REQUEST;
            end

            IMAGE_LOAD: begin
                image_byte <= 0;
                state <= IMAGE_UNPACK;
            end

            IMAGE_UNPACK:
                if (image_byte == 31) begin
                    if (image_index_last) begin
                        index <= 0;
                        state <= BIAS_READ;
                    end else begin
                        index <= index + 1'b1;
                        state <= IMAGE_READ;
                    end
                end else image_byte <= image_byte + 1'b1;

            BIAS_READ: begin
                bus_address <= (READOUT_BIAS + (index << 5)) & 32'hffffffe0;
                bus_write <= 0;
                return_state <= BIAS_LOAD;
                state <= MEMORY_REQUEST;
            end

            BIAS_LOAD: begin
                if (bias_index_last) begin
                    index <= 0;
                    map_word <= 0;
                    state <= MAP_START;
                end else begin
                    index <= index + 1'b1;
                    state <= BIAS_READ;
                end
            end

            MAP_START: begin
                prepare_base <= RETINA_MAP;
                prepare_lines <= PULSE_MAPLINES;
                prepare_start <= 1;
                state <= MAP_GET;
            end

            MAP_GET:
                if (stream_valid) begin
                    map_pixel_address <= {2'b0, stream_data[map_word*32+:8]};
                    onset <= resume ? 6'b0 : stream_data[map_word*32+8+:6];
                    state <= MAP_PIXEL;
                end

            MAP_PIXEL: state <= MAP_LUT;

            MAP_LUT: begin
                current_gray <= pixel_value[7:0];
                map_pixel_address <= {2'b01, map_pixel_address[7:0]};
                state <= MAP_PHASE_READ;
            end
            MAP_PHASE_READ: state <= MAP_PHASE_LOAD;
            MAP_PHASE_LOAD: begin
                current_phase <= pixel_value[11:0];
                state <= MAP_PACK;
            end

            MAP_PACK: begin
                drive_line[map_word*32+:32] <=
                    {6'b0, onset, current_phase, current_gray};
                if (map_word == 5) state <= MAP_WRITE;
                else begin
                    map_word <= map_word + 1'b1;
                    state <= MAP_GET;
                end
            end

            MAP_WRITE: begin
                bus_address <= RETINA_DRIVES + (index << 5);
                bus_data <= drive_line;
                bus_write <= 1;
                return_state <= MAP_NEXT;
                state <= MEMORY_REQUEST;
            end

            MAP_NEXT:
                if (map_index_last) begin
                    slot <= 0;
                    state <= resume ? DONE : WARM_QUEUE_HEADER;
                end else begin
                    index <= index + 1'b1;
                    map_word <= 0;
                    state <= MAP_GET;
                end

            WARM_QUEUE_HEADER: begin
                bus_address <= (WARM_QUEUE + ({27'b0, slot} << 5)) & 32'hffffffe0;
                bus_write <= 0;
                return_state <= WARM_QUEUE_COUNT;
                state <= MEMORY_REQUEST;
            end

            WARM_QUEUE_COUNT: begin
                warm_count <= bus_result[17:0];
                warm_offset <= bus_result[63:32];
                index <= 0;
                warm_last_line <= warm_lines[15:0] - 1'b1;
                pending_events <= pending_events + bus_result[17:0];
                if (bus_result[17:0] > queue_peak) queue_peak <= bus_result[17:0];
                if (bus_count_zero) begin
                    if (slot == 18) begin
                        state <= DONE;
                    end else begin
                        slot <= slot + 1'b1;
                        state <= WARM_QUEUE_HEADER;
                    end
                end else state <= WARM_QUEUE_READ;
            end

            WARM_QUEUE_READ: begin
                prepare_base <= WARM_QUEUE + warm_offset;
                prepare_lines <= ({6'b0, warm_count} + 3) >> 2;
                prepare_start <= 1;
                state <= WARM_QUEUE_COPY;
            end

            WARM_QUEUE_COPY:
                if (stream_valid) begin
                    bus_address <= warm_queue_address;
                    bus_data <= stream_data;
                    bus_write <= 1;
                    return_state <= WARM_QUEUE_NEXT;
                    state <= MEMORY_REQUEST;
                end

            WARM_QUEUE_NEXT:
                if (warm_index_last) begin
                    if (slot == 18) begin
                        state <= DONE;
                    end else begin
                        slot <= slot + 1'b1;
                        state <= WARM_QUEUE_HEADER;
                    end
                end else begin
                    index <= index + 1'b1;
                    state <= WARM_QUEUE_COPY;
                end

            DONE: state <= IDLE;
        endcase
    end
endmodule
