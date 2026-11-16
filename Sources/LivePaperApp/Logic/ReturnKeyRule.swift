// ReturnKeyRule — what Return does in a text box that sends on Return (the AI session's feedback):
// plain Return sends; ⇧Return and ⌥Return add a new line, as in Messages; Return while an input
// method is composing finishes the composition. Foundation only (also compiled into
// LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation

enum ReturnKeyRule {
    enum Action: Equatable {
        case send
        /// What the text view would do anyway: a new line, or finishing an IME composition.
        case asUsual
        /// Swallow the key (nothing to send yet).
        case nothing
    }

    /// `shift`/`option`: modifiers held with Return; `composing`: marked text (IME) is active;
    /// `canSend`: the box's button would do something now (text entered, nothing starting).
    static func action(shift: Bool, option: Bool, composing: Bool, canSend: Bool) -> Action {
        if composing || shift || option { return .asUsual }
        return canSend ? .send : .nothing
    }
}
