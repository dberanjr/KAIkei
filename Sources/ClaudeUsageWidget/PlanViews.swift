import SwiftUI
import UsageCore

/// The Settings > Usage numbers: spend against the monthly limit, and any rate-limit windows the plan has.
/// All of it comes from the cache Claude Code keeps in its own config, so no login token is read.
struct PlanBand: View {
    @EnvironmentObject var store: UsageStore
    let compact: Bool

    var body: some View {
        if let plan = store.dashboard?.plan, let spend = plan.monthlySpend, let limit = plan.monthlyLimit, limit > 0 {
            let percent = plan.spendPercent ?? spend / limit * 100
            let projected = plan.projectedMonthEnd(now: plan.fetchedAt, calendar: .current)
            VStack(alignment: .leading, spacing: 5) {
                if !compact, let account = store.dashboard?.account {
                    Text([account.organization, account.licenseLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Monthly spend limit").font(compact ? .caption.weight(.semibold) : .callout).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(Fmt.money(spend)) of \(Fmt.moneyWhole(limit))").font(.callout.weight(.medium)).monospacedDigit()
                    Text(Fmt.percent(percent)).font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                gauge(percent: percent, projectedFraction: projected.map { $0 / limit })
                if !compact { footnote(percent: percent, projected: projected, plan: plan) }
                if !compact { ForEach(plan.windows, id: \.label) { window($0) } }
            }
            .help("Claude Code caches these figures from Settings > Usage while it runs, so they can trail the Desktop app by a few minutes.")
        }
    }

    private func tint(_ percent: Double) -> Color { percent >= 95 ? Theme.critical : percent >= 80 ? Theme.caution : Theme.accent }

    /// A filled gauge with a tick where month-end spend is heading. The warning is also said in words (see footnote).
    private func gauge(percent: Double, projectedFraction: Double?) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09))
                Capsule().fill(tint(percent)).frame(width: max(6, g.size.width * min(percent / 100, 1)))
                if let f = projectedFraction, f > percent / 100 {
                    Rectangle().fill(.primary.opacity(0.45)).frame(width: 2, height: 12).offset(x: g.size.width * min(f, 1) - 1)
                }
            }
        }
        .frame(height: 7)
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Monthly spend limit")
        .accessibilityValue(Fmt.percent(percent))
    }

    @ViewBuilder private func footnote(percent: Double, projected: Double?, plan: PlanUsage) -> some View {
        HStack(spacing: 8) {
            if percent >= 80 {
                Label(percent >= 100 ? "Limit reached" : "Nearing the limit", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(percent >= 95 ? Theme.critical : Theme.caution)
            }
            if let projected {
                Text("On pace for about \(Fmt.moneyWhole(projected)) this month")
                    .help("Spend so far divided by the share of the month that has passed. It assumes the limit resets on the 1st.")
            }
            Spacer(minLength: 4)
            Text("as of \(plan.fetchedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
    }

    private func window(_ w: PlanWindow) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(w.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let reset = w.resetsAt {
                    Text("resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))").font(.caption).foregroundStyle(.tertiary)
                }
                Text(Fmt.percent(w.percent)).font(.caption.weight(.medium)).monospacedDigit()
            }
            gauge(percent: w.percent, projectedFraction: nil)
        }
    }
}

/// A few headline trend numbers beside the daily chart: this week against last, the daily average, the peak day, cache use.
struct TrendStrip: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        let trend = store.dashboard?.trend ?? TrendSummary()
        let cache = store.snapshot.totalUsage.cacheHitRate
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            tile("Last 7 days", Fmt.money(trend.last7)) { weekOverWeek(trend) }
            tile("Daily average", Fmt.money(trend.dailyAverage)) { Text("last 30 days") }
            if let peak = trend.peak, peak.cost > 0 {
                Clickable(help: "Open \(peak.day.formatted(.dateTime.month().day()))", action: { store.drill(into: .day(peak.day)) }) {
                    tile("Peak day", Fmt.money(peak.cost)) { Text(peak.day.formatted(.dateTime.month().day())) }
                }
            }
            if let cache {
                tile("Cache hit rate", Fmt.percent(cache * 100)) { Text("of input read from cache") }
                    .help("Input served from the prompt cache instead of being re-sent at full price. Higher is cheaper.")
            }
        }
    }

    @ViewBuilder private func weekOverWeek(_ t: TrendSummary) -> some View {
        if let change = t.weekOverWeek {
            // An arrow and a word, not just a color: whether more spend is bad depends on the week.
            let up = change > 0.005, down = change < -0.005
            Label(up ? "up \(Fmt.percent(change * 100))" : down ? "down \(Fmt.percent(-change * 100))" : "flat",
                  systemImage: up ? "arrow.up.right" : down ? "arrow.down.right" : "arrow.right")
        } else {
            Text("no prior week")
        }
    }

    private func tile<Detail: View>(_ label: String, _ value: String, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, weight: .semibold)).monospacedDigit()
            detail().font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
