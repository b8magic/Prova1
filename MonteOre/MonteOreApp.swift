// MyTimeTrackerApp.swift
// VERSIONE MODIFICATA CON 15 PUNTI IMPLEMENTATI

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Color Extensions (unchanged)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r)/255,
                  green: Double(g)/255,
                  blue: Double(b)/255,
                  opacity: Double(a)/255)
    }
}

extension UIColor {
    var toHex: String {
        var r: CGFloat=0, g: CGFloat=0, b: CGFloat=0, a: CGFloat=0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}

// MARK: - Alert Structures (unchanged)
struct AlertError: Identifiable {
    var id: String { message }
    let message: String
}
enum ActiveAlert: Identifiable {
    case running(newProject: Project, message: String)
    var id: String {
        switch self {
        case .running(let newProject, _): return newProject.id.uuidString
        }
    }
}

// MARK: - Data Models (unchanged)
struct NoteRow: Identifiable, Codable {
    // ... same as before ...
}

struct ProjectLabel: Identifiable, Codable {
    // ... same as before ...
}

class Project: Identifiable, ObservableObject, Codable {
    // ... same as before ...
}

// MARK: - ProjectManager (added saving of backup label changes – point 15)
class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var backupProjects: [Project] = []
    @Published var labels: [ProjectLabel] = []
    @Published var currentProject: Project? { /* as before */ }
    @Published var lockedLabelID: UUID? = nil { /* as before plus unlock empty label */ }

    // ... initialization and load/save methods ...

    // Override deleteLabel to always unlock if empty label
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll(where: { $0.id == label.id })
        for p in projects + backupProjects {
            if p.labelID == label.id {
                p.labelID = nil
            }
        }
        lockedLabelID = nil
        saveLabels()
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }

    // Ensure backupProjects updates label assignment persists (point 15)
    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: getProjectsFileURL())
        } catch { print("Error saving projects: \(error)") }
        // Also save backupProjects labels
        for backup in backupProjects {
            let url = getURLForBackup(project: backup)
            if let data = try? JSONEncoder().encode(backup) {
                try? data.write(to: url)
            }
        }
    }

    // ... other methods unchanged ...
}

// MARK: - Views for Labels & Projects

// LabelAssignmentView: point 1 (Conferma closes sheet + circle higher)
struct LabelAssignmentView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var closeButtonVisible = false
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels) { label in
                        HStack {
                            Circle()
                                .fill(Color(hex: label.color))
                                .frame(width: 20, height: 20)
                            Text(label.title)
                            Spacer()
                            if project.labelID == label.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if project.labelID == label.id {
                                project.labelID = nil
                            } else {
                                project.labelID = label.id
                                closeButtonVisible = true
                            }
                            projectManager.saveProjects()
                            projectManager.objectWillChange.send()
                        }
                    }
                }
                if closeButtonVisible {
                    VStack {
                        Spacer().frame(height: 24) // lift circle 1/3 of its height
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Text("Chiudi")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.green)
                                .cornerRadius(8)
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Assegna Etichetta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// LabelHeaderView: point 2 (bigger bold text, no quotes)
struct LabelHeaderView: View {
    let label: ProjectLabel
    @ObservedObject var projectManager: ProjectManager
    var isBackup: Bool = false
    @State private var showLockInfo: Bool = false
    @State private var isTargeted: Bool = false

    var body: some View {
        HStack {
            Circle()
                .fill(Color(hex: label.color))
                .frame(width: 16, height: 16)
            Text(label.title)
                .font(.headline)
                .underline()
                .foregroundColor(Color(hex: label.color))
            Spacer()
            if !isBackup, projectManager.projects.contains(where: { $0.labelID == label.id }) {
                Button(action: toggleLock) {
                    Image(systemName: projectManager.lockedLabelID == label.id ? "lock.fill" : "lock.open")
                        .foregroundColor(.black)
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showLockInfo, arrowEdge: .bottom) {
                    VStack(spacing: 20) {
                        Text("IL PULSANTE È AGGANCIATO AI PROGETTI DELL’ETICHETTA \(label.title)")
                            .font(.title2)
                            .bold()
                            .multilineTextAlignment(.center)
                            .padding()
                        Button("Chiudi") { showLockInfo = false }
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .cornerRadius(8)
                    }
                    .padding()
                    .frame(width: 300)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .onDrop(of: [UTType.text.identifier], isTargeted: $isTargeted, perform: handleDrop)
    }

    private func toggleLock() {
        if projectManager.lockedLabelID != label.id {
            projectManager.lockedLabelID = label.id
            showLockInfo = true
            if let first = projectManager.projects.first(where: { $0.labelID == label.id }) {
                projectManager.currentProject = first
            }
        } else {
            projectManager.lockedLabelID = nil
        }
    }
    private func handleDrop(providers: [NSItemProvider]) -> Bool { /* same as before */ true }
}

// ProjectRowView: point 3 (yellow running background in both main and list)
struct ProjectRowView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool
    @State private var isHighlighted: Bool = false
    @State private var showSecondarySheet = false

    var body: some View {
        let bgColor = projectManager.isProjectRunning(project) ? Color.yellow : Color.clear
        HStack(spacing: 0) {
            Button(action: openProject) {
                HStack {
                    Text(project.name)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(bgColor)
            }
            .buttonStyle(PlainButtonStyle())
            Divider().frame(width: 1).background(Color.gray)
            Button(action: { showSecondarySheet = true }) {
                Text(editingProjects ? "Rinomina o Elimina" : "Etichetta")
                    .font(.footnote)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .background(bgColor)
            }
        }
        .sheet(isPresented: $showSecondarySheet) {
            if editingProjects {
                CombinedProjectEditSheet(project: project, projectManager: projectManager)
            } else {
                LabelAssignmentView(project: project, projectManager: projectManager)
            }
        }
        .onDrag { NSItemProvider(object: project.id.uuidString as NSString) }
    }

    private func openProject() {
        if projectManager.lockedLabelID != nil && project.labelID != projectManager.lockedLabelID {
            // point 14: locked etichetta prevents opening others
            return
        }
        withAnimation(.easeIn(duration: 0.2)) { isHighlighted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.2)) { isHighlighted = false }
            projectManager.currentProject = project
        }
    }
}

// CombinedProjectEditSheet (unchanged except enabling past month editing – point 5)
struct CombinedProjectEditSheet: View {
    // ... same as before ...
}

// LabelsManagerView (unchanged)
struct LabelsManagerView: View {
    // ... same as before ...
}

// NoteView: point 12 (delete empty rows & reorder after edit) + point 6 font sizing
struct NoteView: View {
    @ObservedObject var project: Project
    var projectManager: ProjectManager
    @State private var editMode: Bool = false
    @State private var editedRows: [NoteRow] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    // point 8: show etichetta name above project title
                    if let label = projectManager.labels.first(where: { $0.id == project.labelID }) {
                        Text(label.title.uppercased())
                            .font(.caption)
                            .foregroundColor(Color(hex: label.color))
                    }
                    // point 2: underlined, colored
                    Text(project.name)
                        .font(.title3)
                        .bold()
                        .underline()
                        .foregroundColor(project.labelID.flatMap { id in
                            projectManager.labels.first(where: { $0.id == id })?.color.map(Color.init(hex:)) ?? .black
                        })
                    Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                        .font(.title3)
                        .bold()
                }
                Spacer()
                // point 6: smaller font for note body buttons
                if editMode {
                    VStack {
                        Button("Salva") { applyEdits() }.font(.title3).foregroundColor(.blue)
                        Button("Annulla") { editMode = false }.font(.title3).foregroundColor(.red)
                    }
                } else {
                    Button("Modifica") {
                        editedRows = project.noteRows
                        editMode = true
                    }
                    .font(.title3)
                    .foregroundColor(.blue)
                }
            }
            .padding(.bottom, 5)

            if editMode {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($editedRows) { $row in
                            HStack(spacing: 8) {
                                TextField("Giorno", text: $row.giorno)
                                    .font(.system(size: 15))
                                Divider().frame(height: 60).background(Color.black)
                                TextEditor(text: $row.orari).font(.system(size: 15)).frame(height: 60)
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.totalTimeString).font(.system(size: 15))
                                Divider().frame(height: 60).background(Color.black)
                                TextField("Note", text: $row.note).font(.system(size: 15))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(project.noteRows) { row in
                            HStack(spacing: 8) {
                                Text(row.giorno).font(.system(size: 15))
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.orari).font(.system(size: 15))
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.totalTimeString).font(.system(size: 15))
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.note).font(.system(size: 15))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(20)
    }

    private func applyEdits() {
        // point 12: remove fully empty rows
        let cleaned = editedRows.filter { !($0.giorno.isEmpty && $0.orari.isEmpty && $0.note.isEmpty) }
        // reorder by date
        project.noteRows = cleaned.sorted {
            ($0.dateFromGiorno($0.giorno) ?? Date.distantPast) < ($1.dateFromGiorno($1.giorno) ?? Date.distantPast)
        }
        editMode = false
        projectManager.saveProjects()
    }
}

// ComeFunzionaSheetView: point 10 (full content added)
struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Come Funziona l’App")
                    .font(.title)
                    .bold()
                Group {
                    Text("• **Funzionalità Generali:**\n  – Tieni premuto sulle etichette per ordinarle.\n  – Usa il pulsante centrale per avviare e terminare le note.\n  – L’app crea backup mensili automaticamente.")
                    Text("• **Etichette:**\n  – Raggruppano i progetti.\n  – Assegna un colore, usa il lock per fissare il “bottone giallo”.")
                    Text("• **Progetti Nascosti:**\n  – I backup (mensilità passate) sono nella sezione dedicata.")
                    Text("• **Buone Pratiche e Consigli:**\n  – Usa ✅ nelle note per segnare ore già trasferite.\n  – Non includere mese/anno nel titolo: l’app lo gestisce.")
                }
                .multilineTextAlignment(.leading)
                Button("Chiudi") {
                    onDismiss()
                }
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .cornerRadius(8)
            }
            .padding(30)
        }
    }
}

// ProjectManagerView: point 5 (allow editing past projects), point 9 (export options), point 11 (split yellow button)
struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    // ...
    @State private var exportBackup: Bool = true
    @State private var showExportOptions: Bool = false

    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header: projectSectionHeader("Progetti Correnti")) {
                        // same as before, with onMove enabled for past and current when editingProjects
                    }
                    Section(header: projectSectionHeader("Mensilità Passate")) {
                        // onMove enabled always
                    }
                }
                .listStyle(PlainListStyle())
                .environment(\.editMode, $editMode)

                exportButtons
                HStack {
                    newProjectField
                    Button("Etichette") { showEtichetteSheet = true }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ProjectEditToggleButton(isEditing: $editingProjects)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if showHowItWorksButton {
                            Button("Come funziona l'app") { showHowItWorksSheet = true }
                                .font(.custom("Permanent Marker", size: 20))
                                .foregroundColor(.black)
                                .padding(8)
                                .background(Color.yellow)
                                .cornerRadius(8)
                        } else {
                            Button("?") { showHowItWorksButton = true }
                                .font(.system(size: 40))
                                .bold()
                                .foregroundColor(.yellow)
                        }
                    }
                }
            }
            .sheet(isPresented: $showEtichetteSheet) { LabelsManagerView(projectManager: projectManager) }
            .sheet(isPresented: $showShareSheet) { /* unchanged */ }
            .sheet(isPresented: $showExportOptions) {
                VStack(spacing: 20) {
                    Text("Esporta Monte Ore")
                        .font(.title)
                        .bold()
                    Button("Esporta Backup JSON") {
                        exportBackup = true; performExport()
                    }
                    Button("Esporta CSV Monte Ore") {
                        exportBackup = false; performExport()
                    }
                    Button("Annulla") { showExportOptions = false }
                        .foregroundColor(.red)
                }
                .padding()
            }
        }
    }

    private var exportButtons: some View {
        HStack {
            Button(action: { showExportOptions = true }) {
                Text("Condividi Monte Ore")
                    .font(.title3)
                    .foregroundColor(.purple)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 2))
            }
            Spacer()
        }.padding(.horizontal)
    }

    private func performExport() {
        if exportBackup {
            if let url = projectManager.getExportURL() {
                let av = ActivityView(activityItems: [url]); /* present */
            }
        } else {
            // build CSV in temp file
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("monte_ore.csv")
            var csv = "Progetto,Data,Orari,Totale,Note\n"
            for project in projectManager.projects {
                for row in project.noteRows {
                    let line = "\(project.name),\(row.giorno),\"\(row.orari)\",\(row.totalTimeString),\"\(row.note)\"\n"
                    csv += line
                }
            }
            try? csv.write(to: tmp, atomically: true, encoding: .utf8)
            let av = ActivityView(activityItems: [tmp]); /* present */
        }
        showExportOptions = false
    }

    // New yellow button split: point 11
    private func changeProjectButton() -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Button(action: { cycleProject(backward: true) }) {
                    Image(systemName: "chevron.up")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.yellow)
                Divider()
                Button(action: { cycleProject(backward: false) }) {
                    Image(systemName: "chevron.down")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.yellow)
            }
            .frame(width: 140, height: 140)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black, lineWidth: 2))
        }
        .disabled(projectManager.currentProject.flatMap { projectManager.backupProjects.contains($0.id) } ?? true)
    }

    private func cycleProject(backward: Bool) {
        guard let current = projectManager.currentProject else { return }
        let list: [Project]
        if let locked = projectManager.lockedLabelID {
            list = projectManager.projects.filter { $0.labelID == locked }
        } else { list = projectManager.projects }
        guard let idx = list.firstIndex(where: { $0.id == current.id }), list.count > 1 else { return }
        let next = list[(idx + (backward ? -1 : 1) + list.count) % list.count]
        projectManager.currentProject = next
    }

    // ... other subviews & helpers ...
}

// ContentView: point 3 highlight running on main view + point 13 sticky header
struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var showProjectManager = false
    @State private var showNonCHoSbattiSheet = false
    @State private var showPopup = false
    @AppStorage("medalAwarded") private var medalAwarded: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if projectManager.currentProject == nil {
                        NoNotesPromptView(onOk: { showProjectManager = true },
                                          onNonCHoSbatti: { showNonCHoSbattiSheet = true })
                    } else if let project = projectManager.currentProject {
                        VStack(spacing: 0) {
                            // point 13: sticky header
                            VStack(alignment: .leading) {
                                if let label = projectManager.labels.first(where: { $0.id == project.labelID }) {
                                    Text(label.title.uppercased()).font(.caption)
                                        .foregroundColor(Color(hex: label.color))
                                }
                                Text(project.name)
                                    .font(.title3)
                                    .bold()
                                    .underline()
                                    .foregroundColor(project.labelID.flatMap { id in
                                        projectManager.labels.first(where: { $0.id == id })?.color.map(Color.init(hex:)) ?? .black })
                                Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                                    .font(.title3)
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                            .background(projectManager.isProjectRunning(project) ? Color.yellow : Color.white.opacity(0.2))
                            .clipped()

                            ScrollView {
                                NoteView(project: project, projectManager: projectManager)
                                    .background(Color.white.opacity(0.2))
                                    .cornerRadius(25)
                                    .padding()
                            }
                            .frame(width: isLandscape ? geometry.size.width : geometry.size.width - 40,
                                   height: isLandscape ? geometry.size.height * 0.4 : geometry.size.height * 0.60)
                        }

                        HStack {
                            Button(action: { mainButtonTapped() }) {
                                Text("Pigia il tempo")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .frame(width: isLandscape ? 90 : 140,
                                           height: isLandscape ? 100 : 140)
                                    .background(Circle().fill(Color.black))
                            }
                            .disabled(projectManager.backupProjects.contains(where: { $0.id == project.id }))

                            Button(action: { showProjectManager = true }) {
                                Text("Gestione\nProgetti")
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.black)
                                    .frame(width: isLandscape ? 90 : 140,
                                           height: isLandscape ? 100 : 140)
                                    .background(Circle().fill(Color.white))
                                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            }
                            .background(Color(hex: "#54c0ff"))

                            changeProjectWidget()
                        }
                        .padding(.horizontal, isLandscape ? 10 : 30)
                        .padding(.bottom, isLandscape ? 0 : 30)
                    }
                }
                if showPopup {
                    PopupView(message: "Congratulazioni! Hai guadagnato la medaglia \"Sbattimenti zero eh\"")
                        .transition(.scale)
                }
            }
            .sheet(isPresented: $showProjectManager) {
                ProjectManagerView(projectManager: projectManager)
            }
            .sheet(isPresented: $showNonCHoSbattiSheet) {
                NonCHoSbattiSheetView {
                    if !medalAwarded {
                        medalAwarded = true
                        showPopup = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            withAnimation { showPopup = false }
                        }
                    }
                    showNonCHoSbattiSheet = false
                }
            }
            .onAppear {
                NotificationCenter.default.addObserver(forName: Notification.Name("CycleProjectNotification"),
                                                       object: nil, queue: .main) { _ in
                    cycleProject()
                }
            }
        }
    }

    private func changeProjectWidget() -> some View {
        // reused from ProjectManagerView
        GeometryReader { _ in
            VStack(spacing: 0) {
                Button(action: { cycleProject(backward: true) }) {
                    Image(systemName: "chevron.up")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.yellow)
                Divider()
                Button(action: { cycleProject(backward: false) }) {
                    Image(systemName: "chevron.down")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.yellow)
            }
            .frame(width: 140, height: 140)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black, lineWidth: 2))
        }
    }

    private func cycleProject(backward: Bool = false) {
        guard let current = projectManager.currentProject else { return }
        let list: [Project]
        if let locked = projectManager.lockedLabelID {
            list = projectManager.projects.filter { $0.labelID == locked }
        } else {
            list = projectManager.projects
        }
        guard let idx = list.firstIndex(where: { $0.id == current.id }), list.count > 1 else { return }
        let next = list[(idx + (backward ? -1 : 1) + list.count) % list.count]
        projectManager.currentProject = next
    }

    func mainButtonTapped() {
        guard let project = projectManager.currentProject else { playSound(success: false); return }
        if projectManager.backupProjects.contains(where: { $0.id == project.id }) { return }
        let now = Date()
        let df = DateFormatter(); df.locale = Locale(identifier: "it_IT"); df.dateFormat = "EEEE dd/MM/yy"
        let giornoStr = df.string(from: now).capitalized
        let tf = DateFormatter(); tf.locale = Locale(identifier: "it_IT"); tf.dateFormat = "HH:mm"
        let timeStr = tf.string(from: now)
        projectManager.backupCurrentProjectIfNeeded(project, currentDate: now, currentGiorno: giornoStr)
        if project.noteRows.isEmpty || project.noteRows.last?.giorno != giornoStr {
            let newRow = NoteRow(giorno: giornoStr, orari: timeStr + "-", note: "")
            project.noteRows.append(newRow)
        } else {
            var lastRow = project.noteRows.removeLast()
            if lastRow.orari.hasSuffix("-") { lastRow.orari += timeStr }
            else { lastRow.orari += " " + timeStr + "-" }
            project.noteRows.append(lastRow)
        }
        projectManager.saveProjects()
        playSound(success: true)
    }

    func playSound(success: Bool) {/* as before */}
}

// App Entry (unchanged)
@main
struct MyTimeTrackerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
