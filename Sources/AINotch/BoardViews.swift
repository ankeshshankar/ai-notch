import AppKit
import SwiftUI
import NotchCore

/// The Board, full width like Usage: Needs you, Working, In review, Ready to merge. Four columns
/// when the notch is wide, else four short sections one under the other (an empty one is a single
/// line). A session's card jumps to it, as its row does; a pull request's card opens it in the
/// browser. Idle sessions with no pull request sit in a collapsed footer. Read only.
struct BoardPanel: View {
    var board: Board
    @ObservedObject var links: SessionPRStore
    var title: (SessionState) -> String
    var controller: NotchController
    var now: Double
    var isWide: Bool
    @State private var showsIdle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if board.isEmpty {
                Text("Nothing open").font(.system(size: 11)).foregroundStyle(Palette.ink3).padding(.vertical, 2)
            } else if isWide {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(BoardColumn.allCases, id: \.self) { column in section(column) }
                }
            } else {
                ForEach(BoardColumn.allCases, id: \.self) { column in section(column) }
            }
            if !board.idle.isEmpty { idleFooter }
        }
        .padding(10)
        .panelCard()
    }

    private func tint(_ column: BoardColumn) -> Color {
        switch column {
        case .needsYou: return Palette.waiting
        case .working: return Palette.claude
        case .inReview: return Palette.bitbucket
        case .readyToMerge: return Palette.done
        }
    }

    private func section(_ column: BoardColumn) -> some View {
        let cards = board.cards(column)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(cards.isEmpty ? Palette.ink3 : tint(column)).frame(width: 6, height: 6)
                Text(column.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(cards.isEmpty ? Palette.ink3 : Palette.ink2)
                Text("\(cards.count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Palette.ink3)
                InfoMark(text: column.about)
            }
            ForEach(cards) { card in cardView(card, in: column) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func cardView(_ card: BoardCard, in column: BoardColumn) -> some View {
        if let session = card.session {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    controller.collapse()
                    Jump.to(session)
                } label: {
                    cardLine(dot: AnyView(Circle().fill(dot(session)).frame(width: 6, height: 6)), title: title(session),
                             state: BoardModel.detail(session, now: now), stateColor: Palette.ink3)
                }
                .buttonStyle(RowButtonStyle())
                .help("Jump to this session")
                if let pr = card.pr {
                    SessionPRLine(links: links, session: session, pr: pr)
                }
            }
            .modifier(BoardCardStyle())
        } else if let pr = card.pr {
            Button {
                guard let url = pr.url else { return }
                controller.collapse()
                NSWorkspace.shared.open(url)
            } label: {
                cardLine(dot: AnyView(Image(systemName: "arrow.triangle.pull").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.bitbucket)),
                         title: pr.title, state: PRLine.text(pr), stateColor: tone(pr))
            }
            .buttonStyle(RowButtonStyle())
            .help("\(pr.ref.repoKey) · \(pr.title). Opens the pull request in the browser.")
            .modifier(BoardCardStyle())
        }
    }

    /// A card's first line: a mark, the name, and its state. Narrow, the state sits on the same
    /// line to keep the Board short; in a column it goes under the name.
    private func cardLine(dot: AnyView, title: String, state: String, stateColor: Color) -> some View {
        let name = Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
        let status = Text(state).font(.system(size: 10, weight: .medium)).foregroundStyle(stateColor).lineLimit(1).truncationMode(.tail)
        return Group {
            if isWide {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) { dot; name }
                    status.padding(.leading, 11)
                }
            } else {
                HStack(spacing: 5) {
                    dot
                    name.layoutPriority(1)
                    Spacer(minLength: 6)
                    status
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func dot(_ session: SessionState) -> Color {
        switch session.phase {
        case .waiting: return Palette.waiting
        case .working: return Palette.claude
        case .idle: return Palette.ink3
        }
    }

    private func tone(_ pr: PullRequest) -> Color {
        switch PRLine.tone(pr) {
        case .bad: return Palette.failed
        case .attention: return Palette.waiting
        case .good: return Palette.done
        case .quiet: return Palette.ink3
        }
    }

    /// Idle sessions with no pull request, one line until opened.
    private var idleFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showsIdle.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsIdle ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text("Idle · \(board.idle.count)").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Palette.ink3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsIdle {
                ForEach(board.idle, id: \.id) { session in
                    Button {
                        controller.collapse()
                        Jump.to(session)
                    } label: {
                        HStack(spacing: 6) {
                            Text(title(session)).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(BoardModel.detail(session, now: now)).font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                }
            }
        }
    }
}

private struct BoardCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.subcard))
    }
}
