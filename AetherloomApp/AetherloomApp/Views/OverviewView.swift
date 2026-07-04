import SwiftUI

struct OverviewView: View {
    @Environment(DemoStore.self) private var store

    private let gridColumns = [
        GridItem(.adaptive(minimum: 250), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeroCard()

                if store.massChangeReviewNeeded {
                    SafetyBanner(
                        title: "Paused for safety",
                        message: "Aetherloom found many deletions in “Projects”. This may be intentional, but sync is paused until you review it.",
                        actionTitle: "Review Changes"
                    ) {
                        store.showingPreviewChanges = true
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Connected Locations", accessory: "\(store.healthyServiceCount) of \(store.services.count) available")
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(store.services) { service in
                            ServiceCard(status: service)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Waiting for Preview", accessory: store.plannedChanges.isEmpty ? nil : "Nothing happens without you")
                        PlanSummaryCard()
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Recent Activity", accessory: "Today")
                        RecentActivityCard()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 1220, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ContentBackdrop())
    }
}

// MARK: - Hero

private struct HeroCard: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 84, height: 84)
                Circle()
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    .frame(width: 84, height: 84)
                Image(systemName: store.isScanning ? "arrow.triangle.2.circlepath" : "circle.hexagongrid.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.rotate, isActive: store.isScanning)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(heroTitle)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

                Text("\(store.trackedFileCount.formatted()) files woven across three clouds, this Mac, and your NAS · Last scan \(store.lastScan.lowercased())")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.78))

                HStack(spacing: 8) {
                    if !store.plannedChanges.isEmpty {
                        StatusBadge(text: "\(store.plannedChanges.count) changes waiting for preview", tone: .attention, onDark: true)
                    }
                    if store.unresolvedConflictCount > 0 {
                        StatusBadge(text: "\(store.unresolvedConflictCount) conflict · both versions preserved", tone: .attention, onDark: true)
                    }
                    if store.pausedSyncSetCount > 0 {
                        StatusBadge(text: "\(store.pausedSyncSetCount) paused for safety", tone: .paused, onDark: true)
                    }
                    if store.everythingInSync {
                        StatusBadge(text: "Everything in sync", tone: .healthy, onDark: true)
                    }
                }
                .padding(.top, 5)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    store.scan()
                } label: {
                    Label(store.isScanning ? "Scanning…" : "Scan Now", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(minWidth: 172)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(store.isScanning)

                Button {
                    store.showingPreviewChanges = true
                } label: {
                    Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(minWidth: 172)
                        .background(.white.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            WeaveMesh()
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
    }

    private var heroTitle: String {
        if store.isScanning {
            "Scanning your clouds…"
        } else if store.everythingInSync {
            "Everything is in sync"
        } else {
            "Your clouds, woven together"
        }
    }
}

// MARK: - Service card

struct ServiceCard: View {
    var status: ServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                ServiceMark(service: status.service, size: 36)
                Spacer(minLength: 8)
                StatusBadge(text: status.statusText, tone: status.tone)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(status.service.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(status.account ?? "This Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label(status.selectedFolder, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Checked \(status.lastChecked)", systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let note = status.safetyNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(status.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)

            Button(status.actionTitle) {}
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Plan summary

private struct PlanSummaryCard: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.plannedChanges.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("You're all caught up")
                        .font(.headline)
                    Text("New changes appear here for review before anything happens.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(PlannedChange.Kind.allCases, id: \.self) { kind in
                    let count = store.plannedChanges.filter { $0.kind == kind }.count
                    if count > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: kind.systemImage)
                                .foregroundStyle(kind.tone.color)
                                .frame(width: 22)
                            Text(kind.title)
                            Spacer()
                            Text("\(count)")
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }

                Divider()

                HStack {
                    Label("Nothing is applied without preview", systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.showingPreviewChanges = true
                    } label: {
                        Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Recent activity

private struct RecentActivityCard: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.activity.prefix(4))) { item in
                ActivityRow(item: item)
                    .padding(.vertical, 8)
                if item.id != store.activity.prefix(4).last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

#Preview {
    OverviewView()
        .environment(DemoStore())
        .tint(Theme.accent)
        .frame(width: 1100, height: 800)
}
