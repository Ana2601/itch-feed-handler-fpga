`timescale 1ns/1ps
// Replays the generated 10GbE beat stream into the feed handler at 156.25 MHz,
// compares every BBO update with the golden model, and measures wire-to-BBO
// latency from the beat that carried each message's last byte.
module tb_feed;
    localparam integer MAXB = 400000, MAXM = 200000;

    reg clk = 0, rst_n = 0;
    always #3.2 clk = ~clk;               // 156.25 MHz

    reg  [63:0] s_tdata = 0;
    reg  [7:0]  s_tkeep = 0;
    reg         s_tvalid = 0, s_tlast = 0;
    wire        s_tready, bbo_valid, bbo_side;
    wire [15:0] bbo_locate;
    wire [31:0] bbo_price, bbo_qty, bbo_msg_idx, stat_frames_ok, stat_frames_dropped;
    wire [3:0]  err_flags;

    itch_feed_handler dut (.clk(clk), .rst_n(rst_n), .cfg_udp_port(16'd26400),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
        .bbo_valid(bbo_valid), .bbo_locate(bbo_locate), .bbo_side(bbo_side), .bbo_price(bbo_price),
        .bbo_qty(bbo_qty), .bbo_msg_idx(bbo_msg_idx),
        .stat_frames_ok(stat_frames_ok), .stat_frames_dropped(stat_frames_dropped), .err_flags(err_flags));

    reg [63:0] b_data [0:MAXB-1];
    reg [7:0]  b_keep [0:MAXB-1];
    reg        b_last [0:MAXB-1];
    integer    b_acc  [0:MAXB-1];          // cycle at which each beat was accepted
    integer    m_end  [0:MAXM-1];          // beat index holding each message's last byte
    integer    nbeats = 0, cyc = 0, gap_pct = 0, stall_cycles = 0, bi = 0;
    string     dir;

    always @(posedge clk) cyc <= cyc + 1;

    // watchdog: input must keep moving
    integer last_move = 0;
    always @(posedge clk) begin
        if (s_tvalid && s_tready) last_move = cyc;
        if (rst_n && bi < nbeats && cyc - last_move > 2000) begin
            $display("DEADLOCK at beat %0d/%0d, cycle %0d: parser state=%0d cnt=%0d last_seen=%0d m_valid=%0d",
                     bi, nbeats, cyc, dut.u_parser.st, dut.u_parser.cnt, dut.u_parser.last_seen, dut.u_parser.m_valid);
            $fatal(1, "TEST FAILED");
        end
    end
    integer prog = 0;
    always @(posedge clk) if (bi >= prog + 2000) begin prog = bi; $display("  progress: %0d / %0d beats", bi, nbeats); end

    // ---------------------------------------------------------- source
    always @(posedge clk) if (rst_n) begin
        if (s_tvalid && s_tready) begin
            b_acc[bi] = cyc;
            bi = bi + 1;
        end
        if (s_tvalid && !s_tready) stall_cycles = stall_cycles + 1;
        if (bi < nbeats && (!s_tvalid || s_tready) && $urandom_range(0, 99) >= gap_pct) begin
            s_tvalid <= 1; s_tdata <= b_data[bi]; s_tkeep <= b_keep[bi]; s_tlast <= b_last[bi];
        end else if (s_tvalid && s_tready) begin
            s_tvalid <= 0;
        end
    end

    // ---------------------------------------------------------- scoreboard
    integer fe, r, e_idx, e_loc, e_side, e_px, e_qty, n_ok = 0, n_bad = 0, lat, lat_min = 1 << 30, lat_max = 0;
    longint lat_sum = 0;
    integer lat_hist [0:15];
    always @(posedge clk) if (rst_n && bbo_valid) begin
        r = $fscanf(fe, "%d %d %d %d %d", e_idx, e_loc, e_side, e_px, e_qty);
        if (r != 5) begin
            n_bad = n_bad + 1;
            if (n_bad < 10) $display("ERROR unexpected BBO msg=%0d", bbo_msg_idx);
        end else if (bbo_msg_idx != e_idx || bbo_locate != e_loc || bbo_side != e_side
                     || bbo_price != e_px || bbo_qty != e_qty) begin
            n_bad = n_bad + 1;
            if (n_bad < 10)
                $display("ERROR BBO #%0d: got msg=%0d loc=%0d side=%0d %0d x %0d, expected msg=%0d loc=%0d side=%0d %0d x %0d",
                         n_ok + n_bad, bbo_msg_idx, bbo_locate, bbo_side, bbo_price, bbo_qty, e_idx, e_loc, e_side, e_px, e_qty);
        end else begin
            n_ok = n_ok + 1;
            lat = cyc - b_acc[m_end[bbo_msg_idx]];
            lat_sum = lat_sum + lat;
            if (lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;
            lat_hist[(lat > 15) ? 15 : lat] = lat_hist[(lat > 15) ? 15 : lat] + 1;
        end
    end

    integer f, i, a, b, n_exp = 0, t0, t1;
    reg [63:0] w;
    reg [7:0]  k;
    integer    l;
    initial begin
        if (!$value$plusargs("dir=%s", dir)) dir = "build";
        void'($value$plusargs("gap=%d", gap_pct));
        for (i = 0; i < 16; i = i + 1) lat_hist[i] = 0;
        f = $fopen({dir, "/beats.txt"}, "r");
        while ($fscanf(f, "%h %h %d", w, k, l) == 3) begin
            b_data[nbeats] = w; b_keep[nbeats] = k; b_last[nbeats] = l; nbeats = nbeats + 1;
        end
        $fclose(f);
        f = $fopen({dir, "/msgend.txt"}, "r");
        while ($fscanf(f, "%d %d", a, b) == 2) m_end[a] = b;
        $fclose(f);
        f = $fopen({dir, "/bbo.txt"}, "r");
        while ($fscanf(f, "%d %d %d %d %d", e_idx, e_loc, e_side, e_px, e_qty) == 5) n_exp = n_exp + 1;
        $fclose(f);
        fe = $fopen({dir, "/bbo.txt"}, "r");

        repeat (5) @(posedge clk);
        rst_n = 1;
        t0 = cyc;
        wait (bi == nbeats);
        t1 = cyc;
        repeat (50) @(posedge clk);

        $display("Feed: %0d beats (%0d bytes) in %0d cycles = %.2f Gb/s at 156.25 MHz (input gap %0d%%, %0d ready-stall cycles)",
                 nbeats, nbeats * 8, t1 - t0, 64.0 * nbeats / (t1 - t0) * 0.15625, gap_pct, stall_cycles);
        $display("  frames accepted=%0d dropped=%0d   BBO updates: %0d expected, %0d matched, %0d errors   err_flags=%b",
                 stat_frames_ok, stat_frames_dropped, n_exp, n_ok, n_bad, err_flags);
        $display("  wire-to-BBO latency (cycles after last byte accepted): min %0d  avg %.2f  max %0d   (= %.1f ns min at 6.4 ns/cycle)",
                 lat_min, 1.0 * lat_sum / n_ok, lat_max, lat_min * 6.4);
        $display("  latency histogram: 2:%0d 3:%0d 4:%0d 5:%0d 6:%0d 7+:%0d", lat_hist[2], lat_hist[3], lat_hist[4],
                 lat_hist[5], lat_hist[6], lat_hist[7] + lat_hist[8] + lat_hist[9] + lat_hist[10] + lat_hist[11]
                 + lat_hist[12] + lat_hist[13] + lat_hist[14] + lat_hist[15]);
        if (n_bad != 0 || n_ok != n_exp || err_flags != 0) $fatal(1, "TEST FAILED");
        $display("TEST PASSED");
        $finish;
    end
endmodule
