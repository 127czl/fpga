`timescale 1ns/1ps

// Overlay task/status text and top-right frame-rate/threshold metrics.
// Text has a drop shadow only, no rectangular background.
module isp_task_osd #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] IMG_HTOTAL = 14'd2200,
    parameter [13:0] IMG_VTOTAL = 14'd1125
    )(
    input               clk,
    input               rst_n,
    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_red,
    input       [7:0]   per_img_green,
    input       [7:0]   per_img_blue,
    input       [11:0]  pos_x,
    input       [11:0]  pos_y,
    input       [3:0]   cfg_task,
    input       [1:0]   ddr_mode,
    input       [1:0]   vid_mode,
    input               play_active,
    input       [1:0]   shape_type,
    input signed [12:0] threshold_offset,
    input       [9:0]   status_number,
    input               input_frame_tick,
    input       [3:0]   circle_count,
    input       [3:0]   rect_count,
    input       [2:0]   icon_class,
    input               icon_valid,
    input               icon_enable,
    input               gesture_enable,
    input               gesture_palm_valid,
    input               gesture_roi_valid,
    input               gesture_camera_valid,
    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue
    );

    localparam [13:0] TASK_X  = 14'd32;
    localparam [13:0] TASK_Y  = 14'd24;
    localparam [13:0] STAT_Y  = 14'd104;
    localparam [13:0] AUX_Y   = 14'd144;
    localparam [13:0] ICON_Y  = 14'd184;
    localparam [13:0] METRIC_X = 14'd1600;
    localparam [13:0] FPS_Y   = 14'd24;
    localparam [13:0] THR_Y  = 14'd64;

    reg        vsync_d;
    wire       vsync_rise = per_frame_vsync && !vsync_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d <= 1'b0;
        end else begin
            vsync_d <= per_frame_vsync;
        end
    end

    wire [13:0] draw_x = {2'b00, pos_x};
    wire [13:0] draw_y = {2'b00, pos_y};

    // v90 second-level centre ROI: 336 x 336.
    localparam [13:0] TASK7_ROI_X0 = 14'd792;
    localparam [13:0] TASK7_ROI_X1 = 14'd1127;
    localparam [13:0] TASK7_ROI_Y0 = 14'd372;
    localparam [13:0] TASK7_ROI_Y1 = 14'd707;
    wire task7_roi_on =
        (cfg_task == 4'd6) && icon_enable &&
        (draw_x >= TASK7_ROI_X0 - 2) &&
        (draw_x <= TASK7_ROI_X1 + 2) &&
        (draw_y >= TASK7_ROI_Y0 - 2) &&
        (draw_y <= TASK7_ROI_Y1 + 2) &&
        ((draw_x < TASK7_ROI_X0 + 2) ||
         (draw_x > TASK7_ROI_X1 - 2) ||
         (draw_y < TASK7_ROI_Y0 + 2) ||
         (draw_y > TASK7_ROI_Y1 - 2));

    wire gesture_roi_on =
        (cfg_task == 4'd7) && gesture_enable && (vid_mode != 2'd2) &&
        (draw_x >= 14'd680) && (draw_x <= 14'd1239) &&
        (draw_y >= 14'd380) && (draw_y <= 14'd699) &&
        ((draw_x < 14'd682) || (draw_x > 14'd1237) ||
         (draw_y < 14'd382) || (draw_y > 14'd697));

    localparam [27:0] FPS_WINDOW = 28'd148_500_000;

    reg [27:0] fps_timer;
    reg [15:0] fps_count;
    reg [15:0] fps_value;
    reg [13:0] fps_work;
    reg [2:0]  fps_phase;
    reg [3:0]  fps_d3, fps_d2, fps_d1, fps_d0;

    // Count camera frame starts over one exact 148.5 MHz pixel-clock second.
    // input_frame_tick is a synchronised one-clock pulse from the CSI domain.
    // Decimal conversion then runs in four clocked stages, away from pixels.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fps_timer <= 28'd0;
            fps_count <= 16'd0;
            fps_value <= 16'd0;
            fps_work  <= 14'd0;
            fps_phase <= 3'd0;
            fps_d3 <= 4'd0;
            fps_d2 <= 4'd0;
            fps_d1 <= 4'd0;
            fps_d0 <= 4'd0;
        end else begin
            if (fps_timer >= FPS_WINDOW - 1'b1) begin
                fps_timer <= 28'd0;
                fps_value <= fps_count;
                fps_work  <= fps_count[13:0];
                fps_count <= 16'd0;
                fps_phase <= 3'd1;
            end else begin
                fps_timer <= fps_timer + 1'b1;
                if (input_frame_tick && (fps_count < 16'd9999))
                    fps_count <= fps_count + 1'b1;
            end

            if (fps_phase == 3'd1) begin
                if (fps_work >= 14'd1000) begin
                    fps_d3 <= 4'd1;
                    fps_work <= fps_work - 14'd1000;
                end else
                    fps_d3 <= 4'd0;
                fps_phase <= 3'd2;
            end else if (fps_phase == 3'd2) begin
                if (fps_work >= 14'd900) begin fps_d2 <= 4'd9; fps_work <= fps_work - 14'd900; end
                else if (fps_work >= 14'd800) begin fps_d2 <= 4'd8; fps_work <= fps_work - 14'd800; end
                else if (fps_work >= 14'd700) begin fps_d2 <= 4'd7; fps_work <= fps_work - 14'd700; end
                else if (fps_work >= 14'd600) begin fps_d2 <= 4'd6; fps_work <= fps_work - 14'd600; end
                else if (fps_work >= 14'd500) begin fps_d2 <= 4'd5; fps_work <= fps_work - 14'd500; end
                else if (fps_work >= 14'd400) begin fps_d2 <= 4'd4; fps_work <= fps_work - 14'd400; end
                else if (fps_work >= 14'd300) begin fps_d2 <= 4'd3; fps_work <= fps_work - 14'd300; end
                else if (fps_work >= 14'd200) begin fps_d2 <= 4'd2; fps_work <= fps_work - 14'd200; end
                else if (fps_work >= 14'd100) begin fps_d2 <= 4'd1; fps_work <= fps_work - 14'd100; end
                else fps_d2 <= 4'd0;
                fps_phase <= 3'd3;
            end else if (fps_phase == 3'd3) begin
                if (fps_work >= 14'd90) begin fps_d1 <= 4'd9; fps_work <= fps_work - 14'd90; end
                else if (fps_work >= 14'd80) begin fps_d1 <= 4'd8; fps_work <= fps_work - 14'd80; end
                else if (fps_work >= 14'd70) begin fps_d1 <= 4'd7; fps_work <= fps_work - 14'd70; end
                else if (fps_work >= 14'd60) begin fps_d1 <= 4'd6; fps_work <= fps_work - 14'd60; end
                else if (fps_work >= 14'd50) begin fps_d1 <= 4'd5; fps_work <= fps_work - 14'd50; end
                else if (fps_work >= 14'd40) begin fps_d1 <= 4'd4; fps_work <= fps_work - 14'd40; end
                else if (fps_work >= 14'd30) begin fps_d1 <= 4'd3; fps_work <= fps_work - 14'd30; end
                else if (fps_work >= 14'd20) begin fps_d1 <= 4'd2; fps_work <= fps_work - 14'd20; end
                else if (fps_work >= 14'd10) begin fps_d1 <= 4'd1; fps_work <= fps_work - 14'd10; end
                else fps_d1 <= 4'd0;
                fps_phase <= 3'd4;
            end else if (fps_phase == 3'd4) begin
                fps_d0 <= fps_work[3:0];
                fps_phase <= 3'd0;
            end
        end
    end

    reg [3:0] status_line;
    always @(*) begin
        status_line = 4'hF;
        case (cfg_task)
            4'd6: status_line = (ddr_mode == 2'd0) ? 4'd0 :
                                (ddr_mode == 2'd1) ? 4'd1 : 4'd2;
            4'd7: status_line = (vid_mode == 2'd1) ? 4'd4 :
                                (vid_mode == 2'd2) ?
                                (play_active ? 4'd6 : 4'd5) : 4'd3;
            4'd8: status_line = 4'd7;
            default: status_line = 4'hF;
        endcase
    end

    function [6:0] status_char;
        input [3:0] status_id;
        input [3:0] char_pos;
        begin
            status_char = 7'd0;
            case (status_id)
            4'd0: begin
                case (char_pos)
                4'd0: status_char = 7'd45;
                4'd1: status_char = 7'd26;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd37;
                4'd4: status_char = 7'd52;
                default: status_char = 7'd0;
                endcase
            end
            4'd1: begin
                case (char_pos)
                4'd0: status_char = 7'd61;
                4'd1: status_char = 7'd50;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd41;
                4'd4: status_char = 7'd21;
                4'd5: status_char = 7'd66;
                default: status_char = 7'd0;
                endcase
            end
            4'd2: begin
                case (char_pos)
                4'd0: status_char = 7'd35;
                4'd1: status_char = 7'd42;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd38;
                4'd4: status_char = 7'd58;
                default: status_char = 7'd0;
                endcase
            end
            4'd3: begin
                case (char_pos)
                4'd0: status_char = 7'd61;
                4'd1: status_char = 7'd50;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd49;
                4'd4: status_char = 7'd55;
                default: status_char = 7'd0;
                endcase
            end
            4'd4: begin
                case (char_pos)
                4'd0: status_char = 7'd44;
                4'd1: status_char = 7'd36;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd46;
                4'd4: status_char = 7'd25;
                default: status_char = 7'd0;
                endcase
            end
            4'd5: begin
                case (char_pos)
                4'd0: status_char = 7'd32;
                4'd1: status_char = 7'd51;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd54;
                4'd4: status_char = 7'd20;
                default: status_char = 7'd0;
                endcase
            end
            4'd6: begin
                case (char_pos)
                4'd0: status_char = 7'd57;
                4'd1: status_char = 7'd34;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd32;
                4'd4: status_char = 7'd51;
                default: status_char = 7'd0;
                endcase
            end
            4'd7: begin
                case (char_pos)
                4'd0: status_char = 7'd33;
                4'd1: status_char = 7'd47;
                4'd2: status_char = 7'd0;
                4'd3: status_char = 7'd0;
                4'd4: status_char = 7'd64;
                4'd5: status_char = 7'd47;
                4'd6: status_char = 7'd0;
                default: status_char = 7'd0;
                endcase
            end
            4'd8: begin
                case (char_pos)
                4'd0: status_char = 7'd56;
                4'd1: status_char = 7'd59;
                4'd2: status_char = 7'd24;
                4'd3: status_char = 7'd33;
                4'd4: status_char = 7'd47;
                4'd5: status_char = 7'd0;
                4'd6: status_char = 7'd16;
                4'd7: status_char = 7'd4;
                default: status_char = 7'd0;
                endcase
            end
            4'd9: begin
                case (char_pos)
                4'd0: status_char = 7'd56;
                4'd1: status_char = 7'd59;
                4'd2: status_char = 7'd24;
                4'd3: status_char = 7'd64;
                4'd4: status_char = 7'd47;
                4'd5: status_char = 7'd0;
                4'd6: status_char = 7'd16;
                4'd7: status_char = 7'd4;
                default: status_char = 7'd0;
                endcase
            end
            default: status_char = 7'd0;
            endcase
        end
    endfunction

    function [6:0] digit_char;
        input [3:0] d;
        begin
            case (d)
            4'd0: digit_char = 7'd3;
            4'd1: digit_char = 7'd4;
            4'd2: digit_char = 7'd5;
            4'd3: digit_char = 7'd6;
            4'd4: digit_char = 7'd7;
            4'd5: digit_char = 7'd8;
            4'd6: digit_char = 7'd9;
            4'd7: digit_char = 7'd10;
            4'd8: digit_char = 7'd11;
            4'd9: digit_char = 7'd12;
            default: digit_char = 7'd3;
            endcase
        end
    endfunction


    reg [3:0] thr_d4, thr_d3, thr_d2, thr_d1;
    reg       thr_sign;
    reg [12:0] thr_work;
    reg [2:0]  thr_phase;
    wire [12:0] thr_abs = (threshold_offset < 0) ? -threshold_offset : threshold_offset;

    // Decimal conversion is done once per frame in four small stages. Keeping
    // the arithmetic out of the pixel path lets the font ROM meet the pixel
    // clock timing even with two font instances for the drop shadow.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            thr_d4 <= 4'd0;
            thr_d3 <= 4'd0;
            thr_d2 <= 4'd0;
            thr_d1 <= 4'd0;
            thr_sign <= 1'b0;
            thr_work <= 13'd0;
            thr_phase <= 3'd0;
        end else if (vsync_rise) begin
            thr_sign <= (threshold_offset < 0);
            thr_work <= thr_abs;
            thr_phase <= 3'd1;
        end else if (thr_phase == 3'd1) begin
            if (thr_work >= 13'd1000) begin
                thr_d4 <= 4'd1;
                thr_work <= thr_work - 13'd1000;
            end else
                thr_d4 <= 4'd0;
            thr_phase <= 3'd2;
        end else if (thr_phase == 3'd2) begin
            if (thr_work >= 13'd900) begin thr_d3 <= 4'd9; thr_work <= thr_work - 13'd900; end
            else if (thr_work >= 13'd800) begin thr_d3 <= 4'd8; thr_work <= thr_work - 13'd800; end
            else if (thr_work >= 13'd700) begin thr_d3 <= 4'd7; thr_work <= thr_work - 13'd700; end
            else if (thr_work >= 13'd600) begin thr_d3 <= 4'd6; thr_work <= thr_work - 13'd600; end
            else if (thr_work >= 13'd500) begin thr_d3 <= 4'd5; thr_work <= thr_work - 13'd500; end
            else if (thr_work >= 13'd400) begin thr_d3 <= 4'd4; thr_work <= thr_work - 13'd400; end
            else if (thr_work >= 13'd300) begin thr_d3 <= 4'd3; thr_work <= thr_work - 13'd300; end
            else if (thr_work >= 13'd200) begin thr_d3 <= 4'd2; thr_work <= thr_work - 13'd200; end
            else if (thr_work >= 13'd100) begin thr_d3 <= 4'd1; thr_work <= thr_work - 13'd100; end
            else thr_d3 <= 4'd0;
            thr_phase <= 3'd3;
        end else if (thr_phase == 3'd3) begin
            if (thr_work >= 13'd90) begin thr_d2 <= 4'd9; thr_work <= thr_work - 13'd90; end
            else if (thr_work >= 13'd80) begin thr_d2 <= 4'd8; thr_work <= thr_work - 13'd80; end
            else if (thr_work >= 13'd70) begin thr_d2 <= 4'd7; thr_work <= thr_work - 13'd70; end
            else if (thr_work >= 13'd60) begin thr_d2 <= 4'd6; thr_work <= thr_work - 13'd60; end
            else if (thr_work >= 13'd50) begin thr_d2 <= 4'd5; thr_work <= thr_work - 13'd50; end
            else if (thr_work >= 13'd40) begin thr_d2 <= 4'd4; thr_work <= thr_work - 13'd40; end
            else if (thr_work >= 13'd30) begin thr_d2 <= 4'd3; thr_work <= thr_work - 13'd30; end
            else if (thr_work >= 13'd20) begin thr_d2 <= 4'd2; thr_work <= thr_work - 13'd20; end
            else if (thr_work >= 13'd10) begin thr_d2 <= 4'd1; thr_work <= thr_work - 13'd10; end
            else thr_d2 <= 4'd0;
            thr_phase <= 3'd4;
        end else if (thr_phase == 3'd4) begin
            thr_d1 <= thr_work[3:0];
            thr_phase <= 3'd0;
        end
    end

    reg [9:0] stat_work;
    reg [2:0] stat_phase;
    reg [3:0] stat_d2, stat_d1, stat_d0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_work  <= 10'd0;
            stat_phase <= 3'd0;
            stat_d2 <= 4'd0;
            stat_d1 <= 4'd0;
            stat_d0 <= 4'd0;
        end else if (vsync_rise) begin
            stat_work  <= status_number;
            stat_phase <= 3'd1;
        end else if (stat_phase == 3'd1) begin
            if (stat_work >= 10'd900) begin stat_d2 <= 4'd9; stat_work <= stat_work - 10'd900; end
            else if (stat_work >= 10'd800) begin stat_d2 <= 4'd8; stat_work <= stat_work - 10'd800; end
            else if (stat_work >= 10'd700) begin stat_d2 <= 4'd7; stat_work <= stat_work - 10'd700; end
            else if (stat_work >= 10'd600) begin stat_d2 <= 4'd6; stat_work <= stat_work - 10'd600; end
            else if (stat_work >= 10'd500) begin stat_d2 <= 4'd5; stat_work <= stat_work - 10'd500; end
            else if (stat_work >= 10'd400) begin stat_d2 <= 4'd4; stat_work <= stat_work - 10'd400; end
            else if (stat_work >= 10'd300) begin stat_d2 <= 4'd3; stat_work <= stat_work - 10'd300; end
            else if (stat_work >= 10'd200) begin stat_d2 <= 4'd2; stat_work <= stat_work - 10'd200; end
            else if (stat_work >= 10'd100) begin stat_d2 <= 4'd1; stat_work <= stat_work - 10'd100; end
            else stat_d2 <= 4'd0;
            stat_phase <= 3'd2;
        end else if (stat_phase == 3'd2) begin
            if (stat_work >= 10'd90) begin stat_d1 <= 4'd9; stat_work <= stat_work - 10'd90; end
            else if (stat_work >= 10'd80) begin stat_d1 <= 4'd8; stat_work <= stat_work - 10'd80; end
            else if (stat_work >= 10'd70) begin stat_d1 <= 4'd7; stat_work <= stat_work - 10'd70; end
            else if (stat_work >= 10'd60) begin stat_d1 <= 4'd6; stat_work <= stat_work - 10'd60; end
            else if (stat_work >= 10'd50) begin stat_d1 <= 4'd5; stat_work <= stat_work - 10'd50; end
            else if (stat_work >= 10'd40) begin stat_d1 <= 4'd4; stat_work <= stat_work - 10'd40; end
            else if (stat_work >= 10'd30) begin stat_d1 <= 4'd3; stat_work <= stat_work - 10'd30; end
            else if (stat_work >= 10'd20) begin stat_d1 <= 4'd2; stat_work <= stat_work - 10'd20; end
            else if (stat_work >= 10'd10) begin stat_d1 <= 4'd1; stat_work <= stat_work - 10'd10; end
            else stat_d1 <= 4'd0;
            stat_phase <= 3'd3;
        end else if (stat_phase == 3'd3) begin
            stat_d0 <= stat_work[3:0];
            stat_phase <= 3'd0;
        end
    end

    function [6:0] fps_char;
        input [3:0] char_pos;
        begin
            case (char_pos)
                4'd0: fps_char = 7'd42;
                4'd1: fps_char = 7'd62;
                4'd2: fps_char = 7'd0;
                4'd3: fps_char = digit_char(fps_d3);
                4'd4: fps_char = digit_char(fps_d2);
                4'd5: fps_char = digit_char(fps_d1);
                4'd6: fps_char = digit_char(fps_d0);
                default: fps_char = 7'd0;
            endcase
        end
    endfunction

    function [6:0] aux_char;
        input [3:0] char_pos;
        begin
            case (char_pos)
                4'd0: aux_char = 7'd67;
                4'd1: aux_char = 7'd31;
                4'd2: aux_char = 7'd0;
                4'd3: aux_char = digit_char(stat_d2);
                4'd4: aux_char = digit_char(stat_d1);
                4'd5: aux_char = digit_char(stat_d0);
                default: aux_char = 7'd0;
            endcase
        end
    endfunction

    function [6:0] thr_char;
        input [3:0] char_pos;
        begin
            case (char_pos)
                4'd0: thr_char = 7'd73;
                4'd1: thr_char = 7'd19;
                4'd2: thr_char = 7'd0;
                4'd3: thr_char = thr_sign ? 7'd2 : 7'd1;
                4'd4: thr_char = digit_char(thr_d4);
                4'd5: thr_char = digit_char(thr_d3);
                4'd6: thr_char = digit_char(thr_d2);
                4'd7: thr_char = digit_char(thr_d1);
                default: thr_char = 7'd0;
            endcase
        end
    endfunction

    // Task title and function name are a single pre-rendered badge.
    // The badge is the only place where those two lines can be drawn.
    reg [319:0] badge_mem [0:1023];
    initial $readmemb("src/isp/task_badge.mem", badge_mem);

    wire [3:0] badge_task = (cfg_task <= 4'd9) ? cfg_task : 4'd0;
    wire [13:0] badge_x_wide = (draw_x >= TASK_X) ?
                               (draw_x - TASK_X) : 14'd0;
    wire [13:0] badge_y_wide = (draw_y >= TASK_Y) ?
                               (draw_y - TASK_Y) : 14'd0;
    wire in_badge = (draw_x >= TASK_X) &&
                    (draw_x < TASK_X + 14'd160) &&
                    (draw_y >= TASK_Y) &&
                    (draw_y < TASK_Y + 14'd64);
    wire [7:0] badge_x = badge_x_wide[7:0];
    wire [5:0] badge_y = badge_y_wide[5:0];
    wire [9:0] badge_addr = {badge_task, 6'd0} + {4'd0, badge_y};
    reg [319:0] badge_row_q;
    reg         badge_in_q;
    reg         badge_is_title_q;
    reg  [7:0]  badge_x_q;
    wire badge_core_on = badge_in_q && badge_row_q[319 - badge_x_q];
    wire badge_shadow_on = badge_in_q && badge_row_q[159 - badge_x_q];

    // Dynamic blue status text is also a fixed bitmap.  There is no
    // character loop for tasks 7/8/9, so this line cannot be emitted twice.
    reg [383:0] status_mem [0:511];
    initial $readmemb("src/isp/status_badge.mem", status_mem);

    wire [13:0] status_x_wide = (draw_x >= TASK_X) ?
                                (draw_x - TASK_X) : 14'd0;
    wire [13:0] status_y_wide = (draw_y >= STAT_Y) ?
                                (draw_y - STAT_Y) : 14'd0;
    wire in_status = (status_line != 4'hF) &&
                     (draw_x >= TASK_X) &&
                     (draw_x < TASK_X + 14'd384) &&
                     (draw_y >= STAT_Y) &&
                     (draw_y < STAT_Y + 14'd32);
    wire [8:0] status_x = status_x_wide[8:0];
    wire [4:0] status_y = status_y_wide[4:0];
    wire [8:0] status_addr = {status_line, status_y};
    wire [4:0] status_shadow_y = (status_y >= 5'd2) ?
                                 (status_y - 5'd2) : 5'd0;
    wire [8:0] status_shadow_addr = {status_line, status_shadow_y};
    reg [383:0] status_row_q;
    reg [383:0] status_shadow_row_q;
    reg         status_in_q;
    reg  [8:0]  status_x_q;
    reg  [4:0]  status_y_q;
    wire status_core_on = status_in_q &&
                          status_row_q[383 - status_x_q];
    wire status_shadow_on = status_in_q && (status_x_q >= 9'd2) &&
                            (status_y_q >= 5'd2) &&
                            status_shadow_row_q[383 - (status_x_q - 9'd2)];

    // Dynamic counters use a small bitmap glyph ROM.  They occupy one fixed
    // line below the status badge and never use a character-position loop.
    reg [15:0] digit_mem [0:191];
    initial $readmemb("src/isp/digit_badge.mem", digit_mem);

    wire [3:0] circle_digit = (circle_count > 4'd9) ? 4'd9 : circle_count;
    wire [3:0] rect_digit = (rect_count > 4'd9) ? 4'd9 : rect_count;

    wire [13:0] normal_x_wide = (draw_x >= TASK_X) ?
                                (draw_x - TASK_X) : 14'd0;
    wire [13:0] circle_x_wide = (draw_x >= (TASK_X + 14'd64)) ?
                                (draw_x - (TASK_X + 14'd64)) : 14'd0;
    wire [13:0] rect_x_wide = (draw_x >= (TASK_X + 14'd192)) ?
                              (draw_x - (TASK_X + 14'd192)) : 14'd0;
    wire [13:0] task7_number_y = 14'd144;
    wire [13:0] normal_y_wide = (draw_y >= task7_number_y) ?
                                (draw_y - task7_number_y) : 14'd0;
    wire [13:0] shape_y_wide = (draw_y >= STAT_Y) ?
                               (draw_y - STAT_Y) : 14'd0;

    reg [3:0] counter_glyph;
    reg [3:0] counter_col;
    reg [3:0] counter_row;
    reg       counter_valid;
    always @(*) begin
        counter_glyph = 4'd0;
        counter_col   = 4'd0;
        counter_row   = 4'd0;
        counter_valid = 1'b0;
        if(cfg_task == 4'd8) begin
            if((draw_x >= (TASK_X + 14'd64)) &&
               (draw_x < (TASK_X + 14'd96)) &&
               (draw_y >= STAT_Y) && (draw_y < STAT_Y + 14'd32)) begin
                counter_glyph = circle_digit;
                counter_col   = circle_x_wide[4:1];
                counter_row   = shape_y_wide[4:1];
                counter_valid = 1'b1;
            end else if((draw_x >= (TASK_X + 14'd192)) &&
                        (draw_x < (TASK_X + 14'd224)) &&
                        (draw_y >= STAT_Y) &&
                        (draw_y < STAT_Y + 14'd32)) begin
                counter_glyph = rect_digit;
                counter_col   = rect_x_wide[4:1];
                counter_row   = shape_y_wide[4:1];
                counter_valid = 1'b1;
            end
        end else if((cfg_task == 4'd6) || (cfg_task == 4'd7)) begin
            if((draw_x >= TASK_X) && (draw_x < TASK_X + 14'd96) &&
               (draw_y >= task7_number_y) &&
               (draw_y < task7_number_y + 14'd32)) begin
                case(normal_x_wide[6:5])
                    2'd0: counter_glyph = stat_d2;
                    2'd1: counter_glyph = stat_d1;
                    default: counter_glyph = stat_d0;
                endcase
                counter_col   = normal_x_wide[4:1];
                counter_row   = normal_y_wide[4:1];
                counter_valid = 1'b1;
            end
        end
    end

    wire [7:0] digit_addr = {counter_glyph, counter_row};
    reg  [15:0] digit_row_q;
    reg         counter_valid_q;
    reg  [3:0]  counter_col_q;
    wire counter_core_on = counter_valid_q &&
                           digit_row_q[15 - counter_col_q];
    wire counter_shadow_on = counter_valid_q &&
                             (counter_col_q >= 4'd1) &&
                             digit_row_q[16 - counter_col_q];

    reg [6:0] char_id;
    reg [3:0] glyph_row;
    reg [3:0] glyph_col;
    reg [1:0] text_kind;
    reg       in_text;
    reg [6:0] char_id_q;
    reg [3:0] glyph_row_q;
    reg [3:0] glyph_col_q;
    reg [1:0] text_kind_q;
    reg       text_left_only_q;

    function [6:0] icon_char;
        input [2:0] cls;
        input [1:0] pos;
        begin
            icon_char = 7'd0;
            case (cls)
                3'd0: case (pos)
                    2'd0: icon_char = 7'h4A; // 施
                    2'd1: icon_char = 7'h4B; // 工
                    2'd2: icon_char = 7'h4C; // 路
                    default: icon_char = 7'h4D; // 障
                endcase
                3'd1: case (pos)
                    2'd0: icon_char = 7'h4E; // 行
                    2'd1: icon_char = 7'h4F; // 人
                    2'd2: icon_char = 7'h50; // 警
                    default: icon_char = 7'h51; // 告
                endcase
                3'd2: case (pos)
                    2'd0: icon_char = 7'h52; // 左
                    2'd1: icon_char = 7'h53; // 弯
                    2'd2: icon_char = 7'h50; // 警
                    default: icon_char = 7'h51; // 告
                endcase
                3'd3: case (pos)
                    2'd0: icon_char = 7'h54; // 禁
                    2'd1: icon_char = 7'h55; // 止
                    2'd2: icon_char = 7'h56; // 通
                    default: icon_char = 7'd0;
                endcase
                3'd4: case (pos)
                    2'd0: icon_char = 7'h57; // 限
                    2'd1: icon_char = 7'h58; // 速
                    2'd2: icon_char = 7'h59; // 三
                    default: icon_char = 7'h5A; // 十
                endcase
                3'd5: case (pos)
                    2'd0: icon_char = 7'h5B; // 停
                    2'd1: icon_char = 7'h5C; // 车
                    2'd2: icon_char = 7'h5D; // 指
                    default: icon_char = 7'h5E; // 示
                endcase
                default: icon_char = 7'd0;
            endcase
        end
    endfunction

    always @(*) begin
        char_id = 7'd0;
        glyph_row = 4'd0;
        glyph_col = 4'd0;
        text_kind = 2'd0;
        in_text = 1'b0;

        if ((draw_x >= METRIC_X) && (draw_x < 14'd1888) &&
                     (draw_y >= FPS_Y) && (draw_y < FPS_Y + 14'd32)) begin
            in_text = 1'b1;
            text_kind = 2'd3;
            glyph_row = ((draw_y - FPS_Y) >> 1) & 4'hF;
            glyph_col = ((draw_x - METRIC_X) >> 1) & 4'hF;
            char_id = fps_char((draw_x - METRIC_X) >> 5);
        end else if ((draw_x >= METRIC_X) && (draw_x < 14'd1888) &&
                     (draw_y >= THR_Y) && (draw_y < THR_Y + 14'd32)) begin
            in_text = 1'b1;
            text_kind = 2'd3;
            glyph_row = ((draw_y - THR_Y) >> 1) & 4'hF;
            glyph_col = ((draw_x - METRIC_X) >> 1) & 4'hF;
            char_id = thr_char((draw_x - METRIC_X) >> 5);
        end
    end

    wire [15:0] font_core;
    wire [15:0] font_shadow;
    wire [3:0] shadow_row = glyph_row_q + (glyph_row_q < 4'd15);
    wire       text_left_only = in_text &&
                                ((text_kind == 2'd3) ||
                                 (draw_x < (IMG_HDISP >> 1)));
    wire       core_on = text_left_only_q && font_core[15 - glyph_col_q];
    wire       shadow_on = text_left_only_q && (glyph_col_q < 4'd15) &&
                           (glyph_row_q < 4'd15) &&
                           font_shadow[15 - (glyph_col_q + 1'b1)];

    isp_chinese_font_16x16 u_core_font (
        .char_id(char_id_q), .row(glyph_row_q), .font_row(font_core)
    );
    isp_chinese_font_16x16 u_shadow_font (
        .char_id(char_id_q), .row(shadow_row), .font_row(font_shadow)
    );

    reg [127:0] icon_label_mem [0:191];
    initial $readmemb("src/isp/icon_label_badge.mem", icon_label_mem);
    wire [13:0] icon_text_y = ICON_Y;
    wire icon_text_enable = (cfg_task == 4'd6) && icon_enable;
    wire cn_in_text = icon_text_enable && icon_valid &&
                      (draw_x >= TASK_X) &&
                      (draw_x < TASK_X + 14'd128) &&
                      (draw_y >= icon_text_y) &&
                      (draw_y < icon_text_y + 14'd32);
    wire [4:0] cn_row = draw_y - icon_text_y;
    wire [6:0] cn_col = draw_x - TASK_X;
    wire [7:0] cn_addr = {icon_class, cn_row};
    wire [7:0] cn_shadow_addr = {icon_class,
                                  ((cn_row < 5'd31) ? (cn_row + 1'b1) : cn_row)};
    reg  [127:0] cn_row_bits_q;
    reg  [127:0] cn_shadow_bits_q;
    reg          cn_in_text_q;
    reg   [6:0]  cn_col_q;
    reg   [4:0]  cn_row_q;
    wire cn_core_on = cn_in_text_q && cn_row_bits_q[127 - cn_col_q];
    wire cn_shadow_on = cn_in_text_q &&
                        (cn_col_q < 7'd127) &&
                        (cn_row_q < 5'd31) &&
                        cn_shadow_bits_q[127 - (cn_col_q + 1'b1)];

    // First OSD stage: synchronously read the large bitmap ROMs and carry the
    // pixel/address context with the same one-cycle latency.
    reg [7:0] s1_red, s1_green, s1_blue;
    reg       s1_vsync, s1_href, s1_hsync;
    reg       s1_task7_roi_on;
    reg       s1_gesture_roi_on;
    reg       s1_gesture_camera;
    reg       s1_gesture_palm;
    reg       s1_gesture_roi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            badge_row_q <= 320'd0;
            badge_in_q <= 1'b0;
            badge_is_title_q <= 1'b0;
            badge_x_q <= 8'd0;

            status_row_q <= 384'd0;
            status_shadow_row_q <= 384'd0;
            status_in_q <= 1'b0;
            status_x_q <= 9'd0;
            status_y_q <= 5'd0;

            digit_row_q <= 16'd0;
            counter_valid_q <= 1'b0;
            counter_col_q <= 4'd0;

            char_id_q <= 7'd0;
            glyph_row_q <= 4'd0;
            glyph_col_q <= 4'd0;
            text_kind_q <= 2'd0;
            text_left_only_q <= 1'b0;

            cn_row_bits_q <= 128'd0;
            cn_shadow_bits_q <= 128'd0;
            cn_in_text_q <= 1'b0;
            cn_col_q <= 7'd0;
            cn_row_q <= 5'd0;

            s1_red <= 8'd0;
            s1_green <= 8'd0;
            s1_blue <= 8'd0;
            s1_vsync <= 1'b0;
            s1_href <= 1'b0;
            s1_hsync <= 1'b0;
            s1_task7_roi_on <= 1'b0;
            s1_gesture_roi_on <= 1'b0;
            s1_gesture_camera <= 1'b0;
            s1_gesture_palm <= 1'b0;
            s1_gesture_roi <= 1'b0;
        end else begin
            badge_row_q <= badge_mem[badge_addr];
            badge_in_q <= in_badge;
            badge_is_title_q <= (badge_y < 6'd32);
            badge_x_q <= badge_x;

            status_row_q <= status_mem[status_addr];
            status_shadow_row_q <= status_mem[status_shadow_addr];
            status_in_q <= in_status;
            status_x_q <= status_x;
            status_y_q <= status_y;

            digit_row_q <= digit_mem[digit_addr];
            counter_valid_q <= counter_valid;
            counter_col_q <= counter_col;

            char_id_q <= char_id;
            glyph_row_q <= glyph_row;
            glyph_col_q <= glyph_col;
            text_kind_q <= text_kind;
            text_left_only_q <= text_left_only;

            cn_row_bits_q <= icon_label_mem[cn_addr];
            cn_shadow_bits_q <= icon_label_mem[cn_shadow_addr];
            cn_in_text_q <= cn_in_text;
            cn_col_q <= cn_col;
            cn_row_q <= cn_row;

            s1_red <= per_img_red;
            s1_green <= per_img_green;
            s1_blue <= per_img_blue;
            s1_vsync <= per_frame_vsync;
            s1_href <= per_frame_href;
            s1_hsync <= per_frame_hsync;
            s1_task7_roi_on <= task7_roi_on;
            s1_gesture_roi_on <= gesture_roi_on;
            s1_gesture_camera <= gesture_camera_valid;
            s1_gesture_palm <= gesture_palm_valid;
            s1_gesture_roi <= gesture_roi_valid;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red     <= 8'd0;
            post_img_green   <= 8'd0;
            post_img_blue    <= 8'd0;
        end else begin
            post_frame_vsync <= s1_vsync;
            post_frame_href  <= s1_href;
            post_frame_hsync <= s1_hsync;
            if (badge_core_on) begin
                if (badge_is_title_q) begin
                    post_img_red   <= 8'hFF;
                    post_img_green <= 8'hE8;
                    post_img_blue  <= 8'h50;
                end else begin
                    post_img_red   <= 8'hFF;
                    post_img_green <= 8'hFF;
                    post_img_blue  <= 8'hFF;
                end
            end else if (badge_shadow_on) begin
                post_img_red   <= 8'h08;
                post_img_green <= 8'h08;
                post_img_blue  <= 8'h08;
            end else if (s1_task7_roi_on) begin
                post_img_red   <= 8'h00;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (s1_gesture_roi_on) begin
                if (s1_gesture_camera) begin
                    post_img_red   <= 8'hFF;
                    post_img_green <= 8'h00;
                    post_img_blue  <= 8'h00;
                end else if (s1_gesture_palm) begin
                    post_img_red   <= 8'h00;
                    post_img_green <= 8'hFF;
                    post_img_blue  <= 8'h40;
                end else if (s1_gesture_roi) begin
                    post_img_red   <= 8'h00;
                    post_img_green <= 8'hC0;
                    post_img_blue  <= 8'hFF;
                end else begin
                    post_img_red   <= 8'hFF;
                    post_img_green <= 8'hE8;
                    post_img_blue  <= 8'h00;
                end
            end else if (cn_core_on) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'h00;
                post_img_blue  <= 8'h00;
            end else if (cn_shadow_on) begin
                post_img_red   <= 8'h08;
                post_img_green <= 8'h08;
                post_img_blue  <= 8'h08;
            end else if (status_core_on) begin
                post_img_red   <= 8'h50;
                post_img_green <= 8'hE8;
                post_img_blue  <= 8'hFF;
            end else if (status_shadow_on) begin
                post_img_red   <= 8'h08;
                post_img_green <= 8'h08;
                post_img_blue  <= 8'h08;
            end else if (counter_core_on) begin
                post_img_red   <= 8'h50;
                post_img_green <= 8'hE8;
                post_img_blue  <= 8'hFF;
            end else if (counter_shadow_on) begin
                post_img_red   <= 8'h08;
                post_img_green <= 8'h08;
                post_img_blue  <= 8'h08;
            end else if (core_on) begin
                case (text_kind_q)
                    2'd0: begin post_img_red <= 8'hFF; post_img_green <= 8'hE8; post_img_blue <= 8'h50; end
                    2'd1: begin post_img_red <= 8'hFF; post_img_green <= 8'hFF; post_img_blue <= 8'hFF; end
                    2'd2: begin post_img_red <= 8'h50; post_img_green <= 8'hE8; post_img_blue <= 8'hFF; end
                    default: begin post_img_red <= 8'hFF; post_img_green <= 8'hFF; post_img_blue <= 8'hFF; end
                endcase
            end else if (shadow_on) begin
                post_img_red   <= 8'h08;
                post_img_green <= 8'h08;
                post_img_blue  <= 8'h08;
            end else begin
                post_img_red   <= s1_red;
                post_img_green <= s1_green;
                post_img_blue  <= s1_blue;
            end
        end
    end
endmodule
