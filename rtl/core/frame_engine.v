// Run each frame using the compressed neuron state stored in local RAM.
module frame_engine #(
    parameter N = 166700,
    LANES = 42,
    BIAS1_END = 3555,
    RETINA_BEGIN = 5327,
    RETINA_COUNT = 3335,
    parameter START_T = 2000,
    STEPS = 1000,
    PREFETCH = 64
) (
    input wire clk,
    input wire rst,
    input wire calibrated,
    input wire request,
    input wire [511:0] packet,
    output wire acknowledge,
    output wire [511:0] response,
    output wire busy,
    input wire cmd_ready,
    input wire wr_ready,
    output wire cmd_en,
    output wire cmd_valid,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] wr_data,
    output wire wr_en,
    output wire [31:0] wr_mask,
    input wire rd_valid,
    input wire [255:0] rd_data,
    output wire trace_fire_valid,
    output wire [12:0] trace_fire_row,
    output wire [LANES-1:0] trace_fire_mask,
    output wire [1:0] trace_section
);


    wire resume;
    wire clear_frame, boot_active, run_start, running, classify, query, failed;
    wire [31:0] score_page;
    wire [17:0] query_id;

    wire boot_done, run_done, direct_ready, direct_response;
    wire boot_valid, boot_write, run_valid, run_write;
    wire [31:0] boot_address, run_address;
    wire [255:0] boot_data, run_data;
    wire boot_stream_start, run_stream_start, boot_take, run_take, stream_valid;
    wire [31:0] boot_base, run_base;
    wire [23:0] boot_lines, run_lines;
    wire [255:0] stream_data;
    wire [$clog2(PREFETCH):0] stream_peak;
    wire pixel_mode, pixel_write, pixel_read;
    wire [9:0] pixel_write_address, pixel_address;
    wire [17:0] pixel_write_data, pixel_value;
    wire warm_write;
    wire [12:0] warm_address;
    wire [LANES*24-1:0] warm_data, raw_result;
    wire bias_valid, queue_init_valid;
    wire [1:0] bias_page;
    wire [255:0] bias_data;
    wire [4:0] queue_init_slot;
    wire [17:0] queue_init_count, initial_peak;
    wire [21:0] initial_pending;

    frame_memory #(.PREFETCH(PREFETCH)) memory_access (
        .clk(clk), .rst(rst),
        .direct_valid(boot_active ? boot_valid : run_valid),
        .direct_write(boot_active ? boot_write : run_write),
        .direct_address(boot_active ? boot_address : run_address),
        .direct_data(boot_active ? boot_data : run_data),
        .direct_ready(direct_ready), .direct_response(direct_response),
        .stream_start(boot_active ? boot_stream_start : run_stream_start),
        .stream_base(boot_active ? boot_base : run_base),
        .stream_lines(boot_active ? boot_lines : run_lines),
        .stream_take(boot_active ? boot_take : run_take),
        .stream_valid(stream_valid), .stream_data(stream_data), .stream_peak(stream_peak),
        .pixel_mode(pixel_mode), .pixel_write(pixel_write), .pixel_write_address(pixel_write_address),
        .pixel_write_data(pixel_write_data), .pixel_read(pixel_read),
        .pixel_address(pixel_address), .pixel_value(pixel_value),
        .cmd_ready(cmd_ready), .wr_ready(wr_ready), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_en(cmd_en), .cmd_valid(cmd_valid), .cmd(cmd), .addr(addr),
        .wr_data(wr_data), .wr_en(wr_en), .wr_mask(wr_mask)
    );

    frame_boot #(.N(N), .LANES(LANES), .RETINA_BEGIN(RETINA_BEGIN), .RETINA_COUNT(RETINA_COUNT)) boot (
        .clk(clk), .rst(rst), .start(clear_frame), .resume(resume), .done(boot_done),
        .direct_valid(boot_valid), .direct_write(boot_write), .direct_address(boot_address),
        .direct_data(boot_data), .direct_ready(direct_ready), .direct_response(direct_response),
        .rd_data(rd_data),
        .stream_start(boot_stream_start), .stream_base(boot_base), .stream_lines(boot_lines),
        .stream_take(boot_take), .stream_valid(stream_valid), .stream_data(stream_data),
        .pixel_mode(pixel_mode), .pixel_write(pixel_write), .pixel_write_address(pixel_write_address),
        .pixel_write_data(pixel_write_data), .pixel_read(pixel_read),
        .pixel_address(pixel_address), .pixel_value(pixel_value),
        .raw_write(warm_write), .raw_address(warm_address), .raw_data(warm_data),
        .bias_valid(bias_valid), .bias_page(bias_page), .bias_data(bias_data),
        .queue_valid(queue_init_valid), .queue_slot(queue_init_slot), .queue_count(queue_init_count),
        .pending_events(initial_pending), .queue_peak(initial_peak)
    );

    wire [1:0] run_phase, section;
    reg [1:0] phase = 0;
    always @(posedge clk) begin
        if (rst || clear_frame) phase <= 0;
        else phase <= running ? run_phase : 2'b0;
    end
    wire dense_start, dense_valid, dense_ready, drive_ready;
    wire prepare_input, input_busy;
    wire [12:0] generate_row, fire_row, committed;
    wire [LANES*18-1:0] drives;
    wire fire_valid, fire_ready, fire_buffer_ready, fire_pop_enable, fire_pop;
    wire [LANES-1:0] fires;
    wire fire_any;
    wire [LANES+11:0] queued_fire_data;
    wire [6:0] fire_queue_peak;
    wire edge_active, edge_ready, edge_take, event_valid, event_ready, event_done;
    wire [13:0] edge_left;
    wire [1:0] edge_lane;
    wire [12:0] event_row;
    wire [6:0] event_lane;
    wire signed [17:0] event_weight;
    wire dense_failed, event_failed;
    wire [11:0] frame_step, timestep;
    wire [31:0] total_spikes, total_edges;
    wire [21:0] pending_events, pending_peak;
    wire [17:0] queue_peak;
    wire add_valid, add_done;
    wire [31:0] add_word;

    frame_compute #(.N(N), .LANES(LANES), .RETINA_BEGIN(RETINA_BEGIN), .RETINA_COUNT(RETINA_COUNT),
        .START_T(START_T), .STEPS(STEPS)) compute (
        .clk(clk), .rst(rst || clear_frame), .start(run_start), .resume(resume),
        .abort(dense_failed || event_failed), .done(run_done),
        .direct_valid(run_valid), .direct_write(run_write), .direct_address(run_address),
        .direct_data(run_data), .direct_ready(direct_ready), .direct_response(direct_response),
        .rd_data(rd_data),
        .stream_start(run_stream_start), .stream_base(run_base), .stream_lines(run_lines),
        .stream_take(run_take),
        .drive_ready(drive_ready), .prepare_input(prepare_input), .input_busy(input_busy), .edge_ready(edge_ready), .edge_take(edge_take), .event_done(event_done),
        .fire_pop(fire_pop), .queued_fire_data(queued_fire_data), .committed(committed),
        .add_valid(add_valid), .add_word(add_word), .add_done(add_done),
        .queue_init_valid(queue_init_valid), .queue_init_slot(queue_init_slot),
        .queue_init_count(queue_init_count),
        .initial_pending(initial_pending), .initial_peak(initial_peak),
        .phase(run_phase), .section(section), .dense_start(dense_start), .frame_step(frame_step),
        .fire_pop_enable(fire_pop_enable), .edge_run_active(edge_active), .edge_left(edge_left),
        .edge_lane(edge_lane),
        .timestep(timestep), .total_spikes(total_spikes), .total_edges(total_edges),
        .pending_events(pending_events), .pending_peak(pending_peak), .queue_peak(queue_peak)
    );

    retina_drive #(.N(N), .LANES(LANES), .BIAS1_END(BIAS1_END),
        .RETINA_BEGIN(RETINA_BEGIN), .RETINA_COUNT(RETINA_COUNT)) retina (
        .clk(clk), .rst(rst || clear_frame), .start(dense_start), .frame_step(frame_step),
        .stream_valid(stream_valid), .stream_data(stream_data), .dense_ready(dense_ready),
        .dense_valid(dense_valid), .generate_row(generate_row), .drives(drives), .drive_ready(drive_ready),
        .prepare_input(prepare_input), .input_busy(input_busy)
    );
    edge_decoder #(.LANES(LANES)) edges (
        .clk(clk), .rst(rst || clear_frame), .active(edge_active), .edge_left(edge_left),
        .edge_lane(edge_lane),
        .stream_valid(stream_valid), .stream_data(stream_data), .event_ready(event_ready),
        .edge_ready(edge_ready), .edge_take(edge_take), .event_valid(event_valid),
        .event_row(event_row), .event_lane(event_lane), .event_weight(event_weight)
    );
    spike_rows #(.LANES(LANES)) rows (
        .clk(clk), .rst(rst || clear_frame), .start(dense_start), .pop_enable(fire_pop_enable),
        .fire_valid(fire_valid && phase == 1 && !failed), .fire_row(fire_row), .fires(fires),
        .fire_any(fire_any), .fire_ready(fire_buffer_ready), .fire_pop(fire_pop), .queued_fire_data(queued_fire_data),
        .committed(committed), .fire_queue_peak(fire_queue_peak)
    );
    assign fire_ready = phase == 1 && !failed && fire_buffer_ready;
    assign trace_fire_valid = fire_valid && fire_ready;
    assign trace_fire_row = fire_row;
    assign trace_fire_mask = fires;
    assign trace_section = running ? section : 2'b0;

    wire sample_read, sample_done;
    wire [12:0] sample_row;
    wire [40:0] sample_value;
    state_sample #(.LANES(LANES)) sampler (
        .clk(clk), .rst(rst), .request(query), .neuron(query_id), .raw_result(raw_result),
        .raw_read(sample_read), .raw_row(sample_row), .done(sample_done), .value(sample_value)
    );
    state_array #(.LANES(LANES), .ROWS((N+LANES-1)/LANES)) neurons (
        .clk(clk), .rst(rst || clear_frame), .phase(phase),
        .raw_read(sample_read), .raw_write(warm_write), .raw_address(warm_write ? warm_address : sample_row),
        .raw_data(warm_data), .read_data(raw_result),
        .dense_valid(dense_valid), .dense_ready(dense_ready), .dense_row(generate_row), .dense_drive(drives),
        .fire_valid(fire_valid), .fire_ready(fire_ready), .fire_row(fire_row), .fire(fires), .fire_any(fire_any),
        .dense_failed(dense_failed),
        .event_valid(event_valid && edge_active), .event_ready(event_ready), .event_row(event_row),
        .event_lane(event_lane), .event_weight(event_weight), .event_done(event_done),
        .event_failed(event_failed)
    );

    wire class_done;
    wire [3:0] winner;
    wire [255:0] score_data;
    linear_readout readout (
        .clk(clk), .rst(rst || clear_frame), .bias_valid(bias_valid), .bias_page(bias_page),
        .bias_data(bias_data),
        .add_valid(add_valid), .add_word(add_word), .add_done(add_done), .classify(classify),
        .class_done(class_done), .winner(winner), .page(score_page), .page_data(score_data)
    );

    frame_control #(.START_T(START_T), .PREFETCH(PREFETCH)) control (
        .clk(clk), .rst(rst), .calibrated(calibrated), .request(request), .packet(packet),
        .acknowledge(acknowledge), .response(response), .busy(busy),
        .resume(resume), .clear_frame(clear_frame), .boot_active(boot_active), .run_start(run_start),
        .running(running), .classify(classify), .query(query), .failed(failed),
        .score_page(score_page), .query_id(query_id),
        .boot_done(boot_done), .run_done(run_done), .class_done(class_done), .sample_done(sample_done),
        .dense_failed(dense_failed), .event_failed(event_failed),
        .winner(winner), .score_data(score_data), .sample_value(sample_value),
        .fire_queue_peak(fire_queue_peak), .timestep(timestep),
        .total_spikes(total_spikes), .total_edges(total_edges),
        .pending_peak(pending_peak), .pending_events(pending_events),
        .queue_peak(queue_peak), .stream_peak(stream_peak)
    );
endmodule
