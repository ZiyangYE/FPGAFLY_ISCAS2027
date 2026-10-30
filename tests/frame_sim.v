// Frame simulation includes the DDR command buffer used on the board.
module frame_sim #(
    parameter N=166700,LANES=42,BIAS1_END=3555,RETINA_BEGIN=5327,RETINA_COUNT=3335,
    START_T=2000,STEPS=1000,PREFETCH=64
)(
    input clk,rst,calibrated,request,input [511:0] packet,
    output acknowledge,output [511:0] response,output busy,
    input cmd_ready,wr_ready,output cmd_en,cmd_valid,output [2:0] cmd,
    output [28:0] addr,output [255:0] wr_data,output wr_en,output [31:0] wr_mask,
    input rd_valid,input [255:0] rd_data,
    output trace_fire_valid,output [12:0] trace_fire_row,
    output [LANES-1:0] trace_fire_mask,output [1:0] trace_section
);
    wire core_valid,core_ready;
    wire [2:0] core_command;
    wire [28:0] core_address;
    wire [255:0] core_write_data;
    wire [31:0] core_write_mask;
    assign cmd_valid=cmd_en;
    frame_engine #(.N(N),.LANES(LANES),.BIAS1_END(BIAS1_END),.RETINA_BEGIN(RETINA_BEGIN),
        .RETINA_COUNT(RETINA_COUNT),.START_T(START_T),.STEPS(STEPS),.PREFETCH(PREFETCH)) brain(
        .clk(clk),.rst(rst),.calibrated(calibrated),.request(request),.packet(packet),
        .acknowledge(acknowledge),.response(response),.busy(busy),
        .cmd_ready(core_ready),.wr_ready(core_ready),.cmd_en(),.cmd_valid(core_valid),
        .cmd(core_command),.addr(core_address),.wr_data(core_write_data),.wr_en(),
        .wr_mask(core_write_mask),.rd_valid(rd_valid),.rd_data(rd_data),
        .trace_fire_valid(trace_fire_valid),.trace_fire_row(trace_fire_row),
        .trace_fire_mask(trace_fire_mask),.trace_section(trace_section));
    command_buffer command_pipe(.clk(clk),.rst(rst),
        .in_valid(core_valid),.in_ready(core_ready),.in_cmd(core_command),
        .in_addr(core_address),.in_data(core_write_data),.in_mask(core_write_mask),
        .cmd_ready(cmd_ready),.wr_ready(wr_ready),.cmd_en(cmd_en),.wr_en(wr_en),
        .cmd(cmd),.addr(addr),.data(wr_data),.mask(wr_mask));
    integer clock_count=0, scans=0, rows=0, completed=0;
    always @(posedge clk) begin
        if (rst || brain.clear_frame) begin
            clock_count=0; scans=0; rows=0; completed=0;
        end else begin
            if (busy) clock_count=clock_count+1;
            if (brain.dense_start) begin
                if (brain.timestep != START_T+scans || brain.frame_step != scans) $fatal(1,"step sequence");
                if (rows != scans*((N+LANES-1)/LANES) || completed != rows) $fatal(1,"scan length");
                scans=scans+1;
                if (brain.frame_step==500)
                    $display("HALFWAY cycles=%0d spikes=%0d edges=%0d",clock_count,brain.total_spikes,brain.total_edges);
            end
            if (brain.dense_valid && brain.dense_ready) begin
                rows=rows+1;
            end
            if (trace_fire_valid) completed=completed+1;
            if (brain.classify) begin
                if (scans!=STEPS || rows!=STEPS*((N+LANES-1)/LANES) || completed!=rows) $fatal(1,"final counts");
                $display("COUNTS scans=%0d rows=%0d completed=%0d first=%0d last=%0d",scans,rows,completed,START_T,brain.timestep);
            end
        end
    end

    always @(posedge clk)
        if (!rst && cmd_en && {addr, 2'b00} >= 32'h10990000 &&
            {addr, 2'b00} < 32'h10998000)
            $fatal(1, "Input record sent to DDR");

endmodule
