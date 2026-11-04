`timescale 1ns/1ps

// Debounced two button controller.
//
//   short press : one clock pulse on <key>_short when the key is released
//                 before the long press time
//   long press  : one clock pulse on <key>_long when the hold time is reached,
//                 then repeated every REPEAT_CYCLES while the key stays down
//
// Keys are wired active low with the FPGA internal weak pull up.
module key_ctrl #(
    // 1 = key shorts to ground when pressed (usual board wiring, internal
    //     weak pull up enabled in the pin constraint)
    // 0 = key drives high when pressed
    parameter        KEY_ACTIVE_LOW    = 1'b1,
    // 10 ms @148.5 MHz = 1,485,000 which needs 21 bits, so use 22.
    parameter [21:0] DEBOUNCE_CYCLES   = 22'd1_500_000,
    // 0.5 s @148.5 MHz = 74,250,000. 0.5 s is short enough to be discovered
    // by the user but long enough that a normal tap is never mistaken for a
    // hold.
    // 0.4 s @148.5 MHz = 59,400,000. Shorter than V5's 0.5 s so the long press
    // is easier to reach, while still far above a normal tap.
    parameter [27:0] LONG_PRESS_CYCLES = 28'd59_400_000,
    // 100 ms @148.5 MHz = 14,850,000 which needs 24 bits, so use 25.
    // 60 ms @148.5 MHz = 8,910,000: a faster sweep while the key is held
    parameter [24:0] REPEAT_CYCLES     = 25'd8_910_000
    )(
    input               clk,
    input               rst_n,
    input               key0_n,
    input               key1_n,
    output reg          key0_short,
    output reg          key1_short,
    output reg          key0_long,
    output reg          key1_long,
    output wire         key0_hold,
    output wire         key1_hold
    );

    // ---- synchroniser + debounce for one key ----
    reg  [1:0]  k0_sync;
    reg         k0_stable;
    reg  [21:0] k0_cnt;
    wire        k0_pressed = KEY_ACTIVE_LOW ? ~k0_sync[1] : k0_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k0_sync   <= 2'b11;
            k0_stable <= 1'b0;
            k0_cnt    <= 22'd0;
        end else begin
            k0_sync <= {k0_sync[0], key0_n};
            if (k0_pressed != k0_stable) begin
                if (k0_cnt >= DEBOUNCE_CYCLES) begin
                    k0_stable <= k0_pressed;
                    k0_cnt    <= 22'd0;
                end else
                    k0_cnt <= k0_cnt + 1'b1;
            end else
                k0_cnt <= 22'd0;
        end
    end

    reg  [1:0]  k1_sync;
    reg         k1_stable;
    reg  [21:0] k1_cnt;
    wire        k1_pressed = KEY_ACTIVE_LOW ? ~k1_sync[1] : k1_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k1_sync   <= 2'b11;
            k1_stable <= 1'b0;
            k1_cnt    <= 22'd0;
        end else begin
            k1_sync <= {k1_sync[0], key1_n};
            if (k1_pressed != k1_stable) begin
                if (k1_cnt >= DEBOUNCE_CYCLES) begin
                    k1_stable <= k1_pressed;
                    k1_cnt    <= 22'd0;
                end else
                    k1_cnt <= k1_cnt + 1'b1;
            end else
                k1_cnt <= 22'd0;
        end
    end

    // ---- short / long / repeat for key0 ----
    reg         k0_prev;
    reg [27:0]  k0_hold;
    reg [24:0]  k0_rep;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k0_prev    <= 1'b0;
            k0_hold    <= 28'd0;
            k0_rep     <= 25'd0;
            key0_short <= 1'b0;
            key0_long  <= 1'b0;
        end else begin
            key0_short <= 1'b0;
            key0_long  <= 1'b0;

            if (k0_stable && !k0_prev) begin
                k0_hold <= 28'd0;
                // arm the repeat counter so the very first long pulse is
                // issued the moment the hold time is reached
                k0_rep  <= 25'd0;          // 0 = the long press has not fired yet
            end else if (k0_stable) begin
                if (k0_hold < LONG_PRESS_CYCLES)
                    k0_hold <= k0_hold + 1'b1;
                else if (k0_rep == 25'd0) begin
                    k0_rep    <= 25'd1;    // one shot: no continuous repeat
                    key0_long <= 1'b1;
                end
            end else if (!k0_stable && k0_prev) begin
                if (k0_hold < LONG_PRESS_CYCLES)
                    key0_short <= 1'b1;
            end

            k0_prev <= k0_stable;
        end
    end

    // ---- short / long / repeat for key1 ----
    reg         k1_prev;
    reg [27:0]  k1_hold;
    reg [24:0]  k1_rep;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k1_prev    <= 1'b0;
            k1_hold    <= 28'd0;
            k1_rep     <= 25'd0;
            key1_short <= 1'b0;
            key1_long  <= 1'b0;
        end else begin
            key1_short <= 1'b0;
            key1_long  <= 1'b0;

            if (k1_stable && !k1_prev) begin
                k1_hold <= 28'd0;
                k1_rep  <= 25'd0;
            end else if (k1_stable) begin
                if (k1_hold < LONG_PRESS_CYCLES)
                    k1_hold <= k1_hold + 1'b1;
                else if (k1_rep == 25'd0) begin
                    k1_rep    <= 25'd1;    // one shot: no continuous repeat
                    key1_long <= 1'b1;
                end
            end else if (!k1_stable && k1_prev) begin
                if (k1_hold < LONG_PRESS_CYCLES)
                    key1_short <= 1'b1;
            end

            k1_prev <= k1_stable;
        end
    end

    assign key0_hold = k0_stable;
    assign key1_hold = k1_stable;

endmodule
