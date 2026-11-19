// Stage 2: order table + price-level books + best-bid/offer (BBO) publisher.
//
//  * NSYM tracked instruments (ITCH stock-locate 1..NSYM), bid and ask book each
//  * order table: 2^TBITS entries indexed by the low bits of the order reference,
//    full 64-bit reference stored as a tag, so a lookup can never hit the wrong order.
//    Two LIVE tracked orders must not share an index (raised on err_collision);
//    a production design would use a multi-way hash or CAM here.
//  * each book holds NLVL price levels kept sorted best-first (bids high->low,
//    asks low->high); insert / update / remove of a level is one clock, done with
//    a parallel compare-and-shift across all levels
//  * one book operation per clock; 'U' (replace) needs two (delete + add) and
//    stalls the parser for one cycle
//  * a BBO update is published (registered) whenever the top level of a book
//    changes price or size
module order_book #(
    parameter integer NSYM  = 4,
    parameter integer NLVL  = 16,
    parameter integer TBITS = 10
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        m_valid,
    output wire        m_ready,
    input  wire [7:0]  m_type,
    input  wire [15:0] m_locate,
    input  wire [63:0] m_ref,
    input  wire [63:0] m_newref,
    input  wire        m_side,
    input  wire [31:0] m_shares,
    input  wire [31:0] m_price,
    input  wire [31:0] m_idx,

    output reg         bbo_valid,
    output reg  [15:0] bbo_locate,
    output reg         bbo_side,       // 0 bid, 1 ask
    output reg  [31:0] bbo_price,      // 0 when the side is empty
    output reg  [31:0] bbo_qty,
    output reg  [31:0] bbo_msg_idx,    // message that caused the update

    output reg         err_overflow,   // sticky: more than NLVL price levels on a side
    output reg         err_collision,  // sticky: two live orders hashed to one slot
    output reg         err_book        // sticky: removing size that is not in the book
);
    localparam integer NB = 2 * NSYM;
    localparam integer BW = $clog2(NB);
    localparam integer LW = $clog2(NLVL);

    // ------------------------------------------------------------ order table
    reg              ot_valid [0:(1<<TBITS)-1];
    reg [63:0]       ot_ref   [0:(1<<TBITS)-1];
    reg [BW-1:0]     ot_book  [0:(1<<TBITS)-1];
    reg [31:0]       ot_price [0:(1<<TBITS)-1];
    reg [31:0]       ot_qty   [0:(1<<TBITS)-1];

    // ------------------------------------------------------------ books
    reg              lv_v [0:NB*NLVL-1];
    reg [31:0]       lv_p [0:NB*NLVL-1];
    reg [31:0]       lv_q [0:NB*NLVL-1];

    // ------------------------------------------------------------ decode the operation
    wire [TBITS-1:0] idx      = m_ref[TBITS-1:0];
    wire [TBITS-1:0] nidx     = m_newref[TBITS-1:0];
    wire             hit      = ot_valid[idx] && (ot_ref[idx] == m_ref);
    wire             tracked  = (m_locate >= 16'd1) && (m_locate <= NSYM);
    reg              u_phase;                    // second cycle of a replace

    wire is_add = (m_type == "A") && tracked;
    wire is_red = (m_type == "E" || m_type == "X") && hit;
    wire is_del = (m_type == "D") && hit;
    wire is_rep = (m_type == "U") && (hit || u_phase);

    assign m_ready = !(m_valid && is_rep && !u_phase);

    wire [31:0] red_amt = (m_shares < ot_qty[idx]) ? m_shares : ot_qty[idx];

    // the level operation for this cycle
    reg              op_en;
    reg [BW-1:0]     op_book;
    reg [31:0]       op_price;
    reg [31:0]       op_qty;
    reg              op_remove;                  // 1: subtract op_qty, 0: add
    reg [BW-1:0]     u_book_q;                   // book of the order being replaced
    always @* begin
        op_en = 1'b0; op_book = {BW{1'b0}}; op_price = 32'd0; op_qty = 32'd0; op_remove = 1'b0;
        if (m_valid) begin
            if (is_add) begin
                op_en = 1'b1; op_book = BW'({m_locate - 16'd1, m_side}); op_price = m_price; op_qty = m_shares;
            end else if (is_red) begin
                op_en = 1'b1; op_book = ot_book[idx]; op_price = ot_price[idx]; op_qty = red_amt; op_remove = 1'b1;
            end else if (is_del || (is_rep && !u_phase)) begin
                op_en = 1'b1; op_book = ot_book[idx]; op_price = ot_price[idx]; op_qty = ot_qty[idx]; op_remove = 1'b1;
            end else if (is_rep && u_phase) begin
                op_en = 1'b1; op_book = u_book_q; op_price = m_price; op_qty = m_shares;
            end
        end
    end

    // ------------------------------------------------------------ one-cycle sorted level update
    wire op_ask = op_book[0];
    function automatic better(input ask, input [31:0] a, input [31:0] b);   // a is a better price than b
        better = ask ? (a < b) : (a > b);
    endfunction

    reg        cv [0:NLVL-1];
    reg [31:0] cp [0:NLVL-1], cq [0:NLVL-1];
    reg        nv [0:NLVL-1];
    reg [31:0] np [0:NLVL-1], nq [0:NLVL-1];
    reg        found;
    reg [LW:0] fk, pos;
    reg [31:0] newq;
    reg        ovf, bad;
    integer    i;

    always @* begin
        for (i = 0; i < NLVL; i = i + 1) begin
            cv[i] = lv_v[op_book*NLVL + i]; cp[i] = lv_p[op_book*NLVL + i]; cq[i] = lv_q[op_book*NLVL + i];
            nv[i] = cv[i]; np[i] = cp[i]; nq[i] = cq[i];
        end
        found = 1'b0; fk = 0; pos = 0; ovf = 1'b0; bad = 1'b0; newq = 32'd0;
        for (i = 0; i < NLVL; i = i + 1) begin
            if (cv[i] && cp[i] == op_price) begin found = 1'b1; fk = i[LW:0]; end
            if (cv[i] && better(op_ask, cp[i], op_price)) pos = pos + 1'b1;
        end
        if (op_en) begin
            if (found) begin
                newq = op_remove ? (cq[fk] - op_qty) : (cq[fk] + op_qty);
                if (op_remove && op_qty > cq[fk]) bad = 1'b1;
                if (newq == 32'd0 || bad) begin          // level emptied: close the gap
                    for (i = 0; i < NLVL; i = i + 1)
                        if (i >= fk) begin
                            nv[i] = (i < NLVL - 1) ? cv[i+1] : 1'b0;
                            np[i] = (i < NLVL - 1) ? cp[i+1] : 32'd0;
                            nq[i] = (i < NLVL - 1) ? cq[i+1] : 32'd0;
                        end
                end else begin
                    nq[fk] = newq;
                end
            end else if (!op_remove) begin               // new level: open a gap at `pos`
                ovf = cv[NLVL-1];
                for (i = NLVL - 1; i >= 0; i = i - 1)
                    if (i > pos) begin nv[i] = cv[i-1]; np[i] = cp[i-1]; nq[i] = cq[i-1]; end
                if (pos < NLVL) begin nv[pos] = 1'b1; np[pos] = op_price; nq[pos] = op_qty; end
            end else begin
                bad = (op_qty != 32'd0);                 // removing size from a level that is not there
            end
        end
    end

    wire top_changed = (nv[0] != cv[0]) || (nv[0] && (np[0] != cp[0] || nq[0] != cq[0]));

    // ------------------------------------------------------------ state update
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_phase <= 1'b0; u_book_q <= {BW{1'b0}};
            bbo_valid <= 1'b0; bbo_locate <= 16'd0; bbo_side <= 1'b0; bbo_price <= 32'd0; bbo_qty <= 32'd0;
            bbo_msg_idx <= 32'd0; err_overflow <= 1'b0; err_collision <= 1'b0; err_book <= 1'b0;
            for (j = 0; j < (1 << TBITS); j = j + 1) ot_valid[j] <= 1'b0;
            for (j = 0; j < NB * NLVL; j = j + 1) begin lv_v[j] <= 1'b0; lv_p[j] <= 32'd0; lv_q[j] <= 32'd0; end
        end else begin
            bbo_valid <= 1'b0;

            if (op_en) begin
                for (j = 0; j < NLVL; j = j + 1) begin
                    lv_v[op_book*NLVL + j] <= nv[j]; lv_p[op_book*NLVL + j] <= np[j]; lv_q[op_book*NLVL + j] <= nq[j];
                end
                if (ovf) err_overflow <= 1'b1;
                if (bad) err_book     <= 1'b1;
                if (top_changed) begin
                    bbo_valid   <= 1'b1;
                    bbo_locate  <= 16'(op_book >> 1) + 16'd1;
                    bbo_side    <= op_ask;
                    bbo_price   <= nv[0] ? np[0] : 32'd0;
                    bbo_qty     <= nv[0] ? nq[0] : 32'd0;
                    bbo_msg_idx <= m_idx;
                end
            end

            // order-table maintenance
            if (m_valid) begin
                if (is_add) begin
                    if (ot_valid[idx]) err_collision <= 1'b1;
                    ot_valid[idx] <= 1'b1; ot_ref[idx] <= m_ref; ot_book[idx] <= op_book;
                    ot_price[idx] <= m_price; ot_qty[idx] <= m_shares;
                end else if (is_red) begin
                    ot_qty[idx] <= ot_qty[idx] - red_amt;
                    if (red_amt == ot_qty[idx]) ot_valid[idx] <= 1'b0;
                end else if (is_del) begin
                    ot_valid[idx] <= 1'b0;
                end else if (is_rep && !u_phase) begin
                    ot_valid[idx] <= 1'b0;
                    u_book_q      <= ot_book[idx];
                    u_phase       <= 1'b1;
                end else if (is_rep && u_phase) begin
                    if (ot_valid[nidx]) err_collision <= 1'b1;
                    ot_valid[nidx] <= 1'b1; ot_ref[nidx] <= m_newref; ot_book[nidx] <= u_book_q;
                    ot_price[nidx] <= m_price; ot_qty[nidx] <= m_shares;
                    u_phase <= 1'b0;
                end
            end
        end
    end
endmodule
