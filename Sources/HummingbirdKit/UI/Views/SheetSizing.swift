import SwiftOpenUI

extension View {
    /// Gives a sheet room for its content. Only containers that size
    /// themselves to their content use an ideal size (a desktop sheet, a
    /// tablet form sheet); a full-screen sheet ignores it. Without one, such
    /// a sheet shrinks to its content's narrowest layout and truncates text.
    func sheetSize() -> some View {
        frame(minWidth: 320, idealWidth: 540, maxWidth: .infinity,
              minHeight: 240, idealHeight: 480, maxHeight: .infinity)
    }
}
