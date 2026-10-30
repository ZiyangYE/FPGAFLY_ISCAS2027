// Run the time steps: integrate rows, collect spikes, queue descriptors and deliver edges.
module frame_compute #(
    parameter N=166700, LANES=42, RETINA_BEGIN=5327, RETINA_COUNT=3335, START_T=2000, STEPS=1000
) (
    input clk, rst, start, resume,
    input abort, direct_ready, direct_response,
    input [255:0] rd_data,
    input drive_ready, prepare_input, input_busy, edge_ready, edge_take,
    input event_done, fire_pop,
    input [LANES+11:0] queued_fire_data,
    input [12:0] committed,
    input add_done, queue_init_valid,
    input [4:0] queue_init_slot,
    input [17:0] queue_init_count,
    input [21:0] initial_pending,
    input [17:0] initial_peak,
    output done, direct_valid, direct_write,
    output [31:0] direct_address,
    output [255:0] direct_data,
    output stream_start,
    output [31:0] stream_base,
    output [23:0] stream_lines,
    output stream_take,
    output reg [1:0] phase = 0,
    output reg [1:0] section = 0,
    output dense_start,
    output reg [11:0] frame_step = 0,
    output fire_pop_enable, edge_run_active,
    output [13:0] edge_left,
    output [1:0] edge_lane,
    output add_valid,
    output [31:0] add_word,
    output reg [11:0] timestep = START_T,
    output reg [31:0] total_spikes = 0,
    output [31:0] total_edges,
    output [21:0] pending_events, pending_peak,
    output [17:0] queue_peak
);

    localparam ROWS = (N + LANES - 1) / LANES, WORDS = (N + 255) / 256;
    localparam RFIRST = RETINA_BEGIN / LANES;
    localparam RLAST = (RETINA_BEGIN + RETINA_COUNT - 1) / LANES;
    localparam PULSE_MAPLINES = (RLAST - RFIRST + 1) * ((LANES + 5) / 6);
    localparam SOURCE_DESCRIPTORS=32'h10000000, READOUT_COEFFICIENTS=32'h10400000;
    localparam ORDERED_DESCRIPTORS=32'h10800000, RETINA_DRIVES=32'h10990000;
    localparam IDLE=0, STEP=1, DENSE=2, FIRE_FETCH=3;
    localparam FIRE_SELECT=4, FIRE_GROUP=5, FIRE_ID=6, FIRE_DESCRIPTOR_TEST=7;
    localparam FIRE_DESCRIPTOR=8, FIRE_DESCRIPTOR_LOAD=9, FIRE_BITMAP_WAIT=10, FIRE_BITMAP_LOAD=11;
    localparam FIRE_BITMAP_WRITE=12, COEFFICIENT_READ=13, COEFFICIENT_LOAD=14, SCORE_WAIT=15;
    localparam PARTIAL=16, PARTIAL_LOAD=17, SCAN_START=18, SCAN_LOAD=19;
    localparam SCAN_TEST=20, SCAN_GROUP=21, SCAN_PICK=22, ORDERED_DESCRIPTOR=23;
    localparam ORDERED_DESCRIPTOR_LOAD=24, PUSH_WRITE=25, PUSH_NEXT=26, FLUSH=27;
    localparam DUE_CLEAR=28, DUE=29, STEP_NEXT=30, MEMORY_REQUEST=31;
    localparam MEMORY_RESPONSE=32, CLEAR=33, DONE=34;
    reg [5:0] state = IDLE, return_state;
    reg bus_write;
    reg [31:0] bus_address;
    reg [255:0] bus_data;
    wire [255:0] bus_result;
    reg prepare_start = 0;
    reg [31:0] prepare_base;
    reg [23:0] prepare_lines;
    wire [4:0] current_slot;
    wire [17:0] current_count, future_count;
    wire [31:0] future_queue_address, queue_write_address;
    wire [255:0] queue_pack;
    wire [17:0] source;
    wire source_in_range, fire_empty;
    reg [17:0] original_id;
    reg ordered_hit, descriptor_hit = 0;
    reg [13:0] coeff_index;
    reg [3:0] coeff_left;
    wire descriptor_match, coefficient_match, ordered_match;
    wire [31:0] coefficient_word;
    reg [9:0] bitmap_index = 0;
    wire bitmap_empty;
    wire [17:0] selected_id;
    wire delivery_done, delivery_valid, delivery_start;
    wire [31:0] delivery_address, delivery_base;
    wire [23:0] delivery_lines;
    event_delivery delivery (
        .clk(clk), .rst(rst || abort), .clear(start), .start(state == DUE),
        .slot(current_slot), .count(current_count), .done(delivery_done),
        .direct_valid(delivery_valid), .direct_address(delivery_address),
        .direct_ready(direct_ready), .direct_response(direct_response), .rd_data(rd_data),
        .stream_start(delivery_start), .stream_base(delivery_base), .stream_lines(delivery_lines),
        .edge_take(edge_take), .event_done(event_done), .edge_left(edge_left), .edge_lane(edge_lane),
        .active(edge_run_active), .total_edges(total_edges)
    );
    assign stream_start = prepare_start || delivery_start;
    assign stream_base = state == DUE ? delivery_base : prepare_base;
    assign stream_lines = state == DUE ? delivery_lines : prepare_lines;

    assign done = state == DONE;
    assign dense_start = state == STEP;
    assign fire_pop_enable = state == DENSE;
    assign direct_valid = state == DUE ? delivery_valid : state == MEMORY_REQUEST;
    assign direct_write = state != DUE && bus_write;
    assign direct_address = state == DUE ? delivery_address : bus_address;
    assign direct_data = bus_data;
    assign stream_take = drive_ready || edge_ready && (edge_lane == 3 || edge_left == 1);
    assign add_valid = state == COEFFICIENT_LOAD || state == COEFFICIENT_READ && coefficient_match;
    assign add_word = state == COEFFICIENT_LOAD ? bus_result[coeff_index[2:0]*32+:32] : coefficient_word;

    spike_cursor #(.N(N), .LANES(LANES)) cursor (
        .clk(clk), .load(state == FIRE_FETCH), .row_data(queued_fire_data),
        .select_group(state == FIRE_SELECT), .select_lane(state == FIRE_GROUP),
        .consume(state == FIRE_ID), .empty(fire_empty), .source(source), .in_range(source_in_range)
    );

    descriptor_cache cache (
        .clk(clk), .rst(rst), .source(source),
        .original_id(state == SCAN_PICK ? selected_id : original_id), .coeff_index(coeff_index),
        .ordered_load(state == ORDERED_DESCRIPTOR_LOAD),
        .descriptor_load(state == FIRE_DESCRIPTOR_LOAD), .coefficient_load(state == COEFFICIENT_LOAD),
        .memory_result(state == MEMORY_RESPONSE && direct_response),
        .descriptor_result(state == FIRE_DESCRIPTOR && source_in_range && descriptor_hit),
        .ordered_result(state == ORDERED_DESCRIPTOR && ordered_hit), .rd_data(rd_data),
        .bus_result(bus_result), .descriptor_match(descriptor_match),
        .ordered_match(ordered_match), .coefficient_match(coefficient_match),
        .coefficient_word(coefficient_word)
    );
    spike_scan #(.N(N)) scanner (
        .clk(clk), .rst(rst), .clear(state == CLEAR),
        .mark_address(state == FIRE_DESCRIPTOR_LOAD || state == FIRE_BITMAP_WAIT || state == FIRE_BITMAP_LOAD),
        .mark_capture(state == FIRE_BITMAP_LOAD), .mark_write(state == FIRE_BITMAP_WRITE),
        .scan_start(state == SCAN_START), .scan_load(state == SCAN_LOAD),
        .scan_test(state == SCAN_TEST), .select_bit(state == SCAN_GROUP), .consume(state == SCAN_PICK),
        .index(bitmap_index), .neuron(original_id), .empty(bitmap_empty), .selected_id(selected_id)
    );

    delay_queue #(.START_T(START_T)) queue (
        .clk(clk), .rst(rst), .abort(abort), .start(start && !resume),
        .step(state == STEP), .advance(state == STEP_NEXT),
        .clear_pack(state == PUSH_NEXT || state == DENSE && !fire_pop && committed == ROWS),
        .partial_load(state == PARTIAL_LOAD), .append(state == ORDERED_DESCRIPTOR_LOAD),
        .flush(state == FLUSH), .drained(state == DUE_CLEAR),
        .read_data(bus_result), .entry(bus_result[original_id[1:0]*64+:64]),
        .init_valid(queue_init_valid), .init_slot(queue_init_slot), .init_count(queue_init_count),
        .initial_pending(initial_pending), .initial_peak(initial_peak),
        .current_slot(current_slot), .current_count(current_count), .future_count(future_count),
        .next_address(future_queue_address), .write_address(queue_write_address), .packed_data(queue_pack),
        .pending_events(pending_events), .pending_peak(pending_peak), .queue_peak(queue_peak)
    );

    always @(posedge clk) begin
        prepare_start <= 0;
        if (rst || abort) begin
            state <= IDLE;
            phase <= 0;
            section <= 0;
        end else if (start) begin
            state <= CLEAR;
            bitmap_index <= 0;
            timestep <= START_T;
            frame_step <= 0;
            total_spikes <= 0;
            section <= 0;
        end else begin
            if (prepare_input) begin
                prepare_base <= RETINA_DRIVES;
                prepare_lines <= PULSE_MAPLINES;
                prepare_start <= 1;
            end
            case (state)
                STEP: begin
                    phase <= 1;
                    section <= 1;
                    prepare_base <= RETINA_DRIVES;
                    prepare_lines <= PULSE_MAPLINES;
                    prepare_start <= frame_step == 0;
                    state <= DENSE;
                end

                DENSE:
                    if (fire_pop) state <= FIRE_FETCH;
                    else if (committed == ROWS && !input_busy) begin
                        bitmap_index <= 0;
                        state <= PARTIAL;
                    end

                FIRE_FETCH: state <= FIRE_SELECT;
                FIRE_SELECT: state <= fire_empty ? DENSE : FIRE_GROUP;
                FIRE_GROUP: state <= FIRE_ID;
                FIRE_ID: state <= FIRE_DESCRIPTOR_TEST;

                FIRE_DESCRIPTOR_TEST: begin
                    descriptor_hit <= descriptor_match;
                    state <= FIRE_DESCRIPTOR;
                end

                FIRE_DESCRIPTOR:
                    if (source_in_range) begin
                        total_spikes <= total_spikes + 1'b1;
                        if (descriptor_hit) begin
                            state <= FIRE_DESCRIPTOR_LOAD;
                        end else begin
                            bus_address <= (SOURCE_DESCRIPTORS + ({14'b0, source} << 4)) & 32'hffffffe0;
                            bus_write <= 0;
                            return_state <= FIRE_DESCRIPTOR_LOAD;
                            state <= MEMORY_REQUEST;
                        end
                    end else state <= FIRE_SELECT;

                FIRE_DESCRIPTOR_LOAD: begin
                    if (source[0]) begin
                        original_id <= bus_result[209:192];
                        coeff_index <= bus_result[180:167];
                        coeff_left <= bus_result[184:181];
                    end else begin
                        original_id <= bus_result[81:64];
                        coeff_index <= bus_result[52:39];
                        coeff_left <= bus_result[56:53];
                    end
                    state <= FIRE_BITMAP_WAIT;
                end

                FIRE_BITMAP_WAIT: state <= FIRE_BITMAP_LOAD;

                FIRE_BITMAP_LOAD: state <= FIRE_BITMAP_WRITE;

                FIRE_BITMAP_WRITE: state <= coeff_left != 0 ? COEFFICIENT_READ : FIRE_SELECT;

                COEFFICIENT_READ:
                    if (coefficient_match) begin
                        state <= SCORE_WAIT;
                    end else begin
                        bus_address <= (READOUT_COEFFICIENTS + ({18'b0, coeff_index} << 2)) & 32'hffffffe0;
                        bus_write <= 0;
                        return_state <= COEFFICIENT_LOAD;
                        state <= MEMORY_REQUEST;
                    end

                COEFFICIENT_LOAD: state <= SCORE_WAIT;

                SCORE_WAIT: if (add_done) begin
                    coeff_index <= coeff_index + 1'b1;
                    coeff_left <= coeff_left - 1'b1;
                    state <= coeff_left == 1 ? FIRE_SELECT : COEFFICIENT_READ;
                end

                PARTIAL: begin
                    section <= 2;
                    if (future_count[1:0] != 0) begin
                        bus_address <= (future_queue_address) & 32'hffffffe0;
                        bus_write <= 0;
                        return_state <= PARTIAL_LOAD;
                        state <= MEMORY_REQUEST;
                    end else state <= SCAN_START;
                end

                PARTIAL_LOAD: state <= SCAN_START;

                SCAN_START: state <= SCAN_LOAD;

                SCAN_LOAD: state <= SCAN_TEST;

                SCAN_TEST:
                    if (bitmap_empty) begin
                        if (bitmap_index == WORDS - 1) state <= FLUSH;
                        else begin
                            bitmap_index <= bitmap_index + 1'b1;
                        end
                    end else begin
                        state <= SCAN_GROUP;
                    end

                SCAN_GROUP: state <= SCAN_PICK;

                SCAN_PICK: begin
                    original_id <= selected_id;
                    state <= ORDERED_DESCRIPTOR;
                    ordered_hit <= ordered_match;
                end

                ORDERED_DESCRIPTOR:
                    if (ordered_hit) begin
                        state <= ORDERED_DESCRIPTOR_LOAD;
                    end else begin
                        bus_address <= (ORDERED_DESCRIPTORS + ({14'b0, original_id} << 3)) & 32'hffffffe0;
                        bus_write <= 0;
                        return_state <= ORDERED_DESCRIPTOR_LOAD;
                        state <= MEMORY_REQUEST;
                    end

                ORDERED_DESCRIPTOR_LOAD: state <= future_count[1:0] == 3 ? PUSH_WRITE : SCAN_TEST;

                PUSH_WRITE: begin
                    bus_address <= queue_write_address;
                    bus_data <= queue_pack;
                    bus_write <= 1;
                    return_state <= PUSH_NEXT;
                    state <= MEMORY_REQUEST;
                end

                PUSH_NEXT: state <= SCAN_TEST;

                FLUSH: begin
                    phase <= 2;
                    section <= 3;
                    if (future_count[1:0] != 0) begin
                        bus_address <= future_queue_address;
                        bus_data <= queue_pack;
                        bus_write <= 1;
                        return_state <= DUE;
                        state <= MEMORY_REQUEST;
                    end else state <= DUE;
                end

                DUE_CLEAR: state <= STEP_NEXT;

                DUE: if (delivery_done) state <= DUE_CLEAR;

                STEP_NEXT:
                    if (frame_step == STEPS - 1) begin
                        state <= DONE;
                    end else begin
                        timestep <= timestep + 1'b1;
                        frame_step <= frame_step + 1'b1;
                        state <= STEP;
                    end

                MEMORY_REQUEST: if (direct_ready) state <= bus_write ? return_state : MEMORY_RESPONSE;
                MEMORY_RESPONSE: if (direct_response) state <= return_state;
                CLEAR: if (bitmap_index == WORDS - 1) state <= STEP;
                    else bitmap_index <= bitmap_index + 1'b1;
                DONE: state <= IDLE;
            endcase
        end
    end
endmodule
