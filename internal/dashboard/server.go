package dashboard

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-redis/redis/v8"
)

type Server struct {
	rdb  *redis.Client
	addr string
}

func NewServer(redisAddr, addr string) (*Server, error) {
	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping failed: %w", err)
	}
	return &Server{rdb: rdb, addr: addr}, nil
}

func (s *Server) Run(ctx context.Context) error {
	r := chi.NewRouter()
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	r.Get("/", s.handleIndex)
	r.Get("/api/metrics", s.handleMetrics)

	srv := &http.Server{
		Addr:    s.addr,
		Handler: r,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("dashboard listening on %s", s.addr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		return ctx.Err()
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}

type MetricsResponse struct {
	BidRequests        int64             `json:"bid_requests"`
	DedupedImpressions int64             `json:"deduped_impressions"`
	UnknownImpressions int64             `json:"unknown_impressions"`
	ViewRate           float64           `json:"view_rate"`
	Dimension          string            `json:"dimension"`
	Breakdown          []BreakdownBucket `json:"breakdown"`
}

type BreakdownBucket struct {
	Value              string `json:"value"`
	BidRequests        int64  `json:"bid_requests"`
	DedupedImpressions *int64 `json:"deduped_impressions,omitempty"`
}

func (s *Server) handleIndex(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(indexHTML))
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	dim := strings.TrimSpace(r.URL.Query().Get("dimension"))
	if dim == "" {
		dim = "campaign"
	}
	if dim != "campaign" && dim != "placement" && dim != "app_bundle" {
		http.Error(w, "invalid dimension", http.StatusBadRequest)
		return
	}

	totalBids := s.getInt(ctx, "agg:bid_requests")
	totalImps := s.getInt(ctx, "agg:deduped_impressions")
	unknown := s.getInt(ctx, "agg:unknown_impressions")

	viewRate := 0.0
	if totalBids > 0 {
		viewRate = float64(totalImps) / float64(totalBids)
	}

	values, err := s.rdb.SMembers(ctx, "dim:"+dim).Result()
	if err != nil {
		http.Error(w, "redis error", http.StatusInternalServerError)
		return
	}
	sort.Strings(values)

	resp := MetricsResponse{
		BidRequests:        totalBids,
		DedupedImpressions: totalImps,
		UnknownImpressions: unknown,
		ViewRate:           viewRate,
		Dimension:          dim,
		Breakdown:          make([]BreakdownBucket, 0, len(values)),
	}

	// For campaign we have both bid and impression aggregates; for others we only have bids today.
	includeImps := dim == "campaign"

	bidKeys := make([]string, 0, len(values))
	impKeys := make([]string, 0, len(values))
	for _, v := range values {
		bidKeys = append(bidKeys, fmt.Sprintf("agg:%s:%s:bids", dim, v))
		if includeImps {
			impKeys = append(impKeys, fmt.Sprintf("agg:%s:%s:impressions_dedup", dim, v))
		}
	}

	bidVals := s.mgetInts(ctx, bidKeys)
	var impVals []int64
	if includeImps {
		impVals = s.mgetInts(ctx, impKeys)
	}

	for i, v := range values {
		b := BreakdownBucket{
			Value:       v,
			BidRequests: bidVals[i],
		}
		if includeImps {
			imps := impVals[i]
			b.DedupedImpressions = &imps
		}
		resp.Breakdown = append(resp.Breakdown, b)
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *Server) getInt(ctx context.Context, key string) int64 {
	v, err := s.rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		return 0
	}
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func (s *Server) mgetInts(ctx context.Context, keys []string) []int64 {
	out := make([]int64, len(keys))
	if len(keys) == 0 {
		return out
	}
	vals, err := s.rdb.MGet(ctx, keys...).Result()
	if err != nil {
		return out
	}
	for i, v := range vals {
		if v == nil {
			out[i] = 0
			continue
		}
		switch t := v.(type) {
		case string:
			n, err := strconv.ParseInt(t, 10, 64)
			if err == nil {
				out[i] = n
			}
		default:
			// ignore
		}
	}
	return out
}

const indexHTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>Zarli Metrics Dashboard</title>
    <style>
      :root {
        --bg: #0b0d12;
        --panel: rgba(255,255,255,0.06);
        --text: rgba(255,255,255,0.92);
        --muted: rgba(255,255,255,0.62);
        --line: rgba(255,255,255,0.12);
        --accent: #77f2c3;
        --accent2: #7aa7ff;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji", "Segoe UI Emoji";
        color: var(--text);
        background:
          radial-gradient(1200px 700px at 15% 0%, rgba(122,167,255,0.20), transparent 60%),
          radial-gradient(1000px 650px at 90% 10%, rgba(119,242,195,0.18), transparent 55%),
          radial-gradient(900px 600px at 50% 100%, rgba(255,255,255,0.06), transparent 55%),
          var(--bg);
        min-height: 100vh;
      }
      header {
        padding: 28px 18px 12px;
        max-width: 1100px;
        margin: 0 auto;
      }
      h1 {
        margin: 0;
        font-size: 22px;
        letter-spacing: 0.2px;
      }
      .sub {
        margin-top: 8px;
        color: var(--muted);
        font-size: 13px;
      }
      .wrap {
        max-width: 1100px;
        margin: 0 auto;
        padding: 0 18px 40px;
      }
      .row {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 12px;
        margin-top: 14px;
      }
      .card {
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 16px;
        padding: 14px 14px 12px;
        backdrop-filter: blur(8px);
      }
      .k { color: var(--muted); font-size: 12px; }
      .v { margin-top: 8px; font-size: 22px; font-weight: 650; }
      .v.accent { color: var(--accent); }
      .controls {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        margin-top: 16px;
      }
      select {
        background: rgba(255,255,255,0.08);
        border: 1px solid var(--line);
        color: var(--text);
        padding: 10px 10px;
        border-radius: 12px;
        outline: none;
      }
      .hint { color: var(--muted); font-size: 12px; }
      table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 12px;
        overflow: hidden;
        border-radius: 16px;
        border: 1px solid var(--line);
        background: rgba(0,0,0,0.18);
      }
      th, td {
        text-align: left;
        padding: 10px 12px;
        border-bottom: 1px solid rgba(255,255,255,0.08);
        font-size: 13px;
      }
      th { color: rgba(255,255,255,0.78); font-weight: 600; }
      td.num { text-align: right; font-variant-numeric: tabular-nums; }
      .pill {
        display: inline-flex;
        gap: 8px;
        align-items: center;
        padding: 8px 10px;
        border-radius: 999px;
        border: 1px solid var(--line);
        background: rgba(255,255,255,0.06);
        color: rgba(255,255,255,0.86);
        font-size: 12px;
      }
      .dot {
        width: 8px;
        height: 8px;
        border-radius: 999px;
        background: var(--accent2);
      }
      @media (max-width: 860px) {
        .row { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      }
      @media (max-width: 520px) {
        .row { grid-template-columns: 1fr; }
        .controls { flex-direction: column; align-items: flex-start; }
      }
    </style>
  </head>
  <body>
    <header>
      <h1>Metrics Dashboard</h1>
      <div class="sub">View Rate = deduped impressions / bid requests. Data source: Redis aggregates from Deliverable B.</div>
    </header>

    <div class="wrap">
      <div class="row">
        <div class="card">
          <div class="k">View Rate</div>
          <div class="v accent" id="viewRate">-</div>
        </div>
        <div class="card">
          <div class="k">Bid Requests</div>
          <div class="v" id="bids">-</div>
        </div>
        <div class="card">
          <div class="k">Deduped Impressions</div>
          <div class="v" id="imps">-</div>
        </div>
        <div class="card">
          <div class="k">Unknown Impressions</div>
          <div class="v" id="unknown">-</div>
        </div>
      </div>

      <div class="controls">
        <div class="pill"><span class="dot"></span><span id="status">loading</span></div>
        <div>
          <label class="hint">Breakdown dimension</label><br />
          <select id="dimension">
            <option value="campaign">campaign</option>
            <option value="placement">placement</option>
            <option value="app_bundle">app_bundle</option>
          </select>
        </div>
      </div>

      <table>
        <thead>
          <tr>
            <th style="width: 55%">Value</th>
            <th style="width: 22%; text-align:right">Bid Requests</th>
            <th style="width: 23%; text-align:right">Deduped Impressions</th>
          </tr>
        </thead>
        <tbody id="rows"></tbody>
      </table>
    </div>

    <script>
      const $ = (id) => document.getElementById(id);
      const fmtInt = (n) => new Intl.NumberFormat().format(n);
      const fmtRate = (r) => (r * 100).toFixed(3) + "%";

      async function load() {
        const dim = $("dimension").value;
        $("status").textContent = "loading";
        const res = await fetch("/api/metrics?dimension=" + encodeURIComponent(dim));
        if (!res.ok) {
          $("status").textContent = "error " + res.status;
          return;
        }
        const data = await res.json();
        $("viewRate").textContent = fmtRate(data.view_rate || 0);
        $("bids").textContent = fmtInt(data.bid_requests || 0);
        $("imps").textContent = fmtInt(data.deduped_impressions || 0);
        $("unknown").textContent = fmtInt(data.unknown_impressions || 0);

        const showImps = (data.dimension === "campaign");
        const rows = data.breakdown || [];
        const tbody = $("rows");
        tbody.innerHTML = "";
        for (const b of rows) {
          const tr = document.createElement("tr");
          const tdV = document.createElement("td");
          tdV.textContent = b.value;
          const tdB = document.createElement("td");
          tdB.className = "num";
          tdB.textContent = fmtInt(b.bid_requests || 0);
          const tdI = document.createElement("td");
          tdI.className = "num";
          if (showImps && b.deduped_impressions != null) {
            tdI.textContent = fmtInt(b.deduped_impressions);
          } else {
            tdI.textContent = "-";
          }
          tr.appendChild(tdV);
          tr.appendChild(tdB);
          tr.appendChild(tdI);
          tbody.appendChild(tr);
        }
        $("status").textContent = "ok (" + data.dimension + ")";
      }

      $("dimension").addEventListener("change", load);
      load();
      setInterval(load, 2500);
    </script>
  </body>
</html>`
