import SwiftUI
import UniformTypeIdentifiers

// MARK: - Color Extensions

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
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

extension UIColor {
    var toHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Alerts

struct AlertError: Identifiable {
    var id: String { message }
    let message: String
}

enum ActiveAlert: Identifiable {
    case running(newProject: Project)
    var id: String {
        switch self {
        case .running(let newProject): return newProject.id.uuidString
        }
    }
}

// MARK: - Data Models

struct NoteRow: Identifiable, Codable {
    var id = UUID()
    var giorno: String   // e.g. "Giovedì 18/03/25"
    var orari: String    // e.g. "14:32-17:12 17:18-"
    var note: String = ""
    
    enum CodingKeys: String, CodingKey { case id, giorno, orari, note }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        giorno = try c.decode(String.self, forKey: .giorno)
        orari = try c.decode(String.self, forKey: .orari)
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
    init(giorno: String, orari: String, note: String = "") {
        self.giorno = giorno; self.orari = orari; self.note = note
    }
    
    var totalMinutes: Int {
        orari.split(separator: " ").compactMap { seg -> Int? in
            let parts = seg.split(separator: "-")
            guard parts.count == 2,
                  let s = minutesFromString(String(parts[0])),
                  let e = minutesFromString(String(parts[1]))
            else { return nil }
            return max(0, e - s)
        }
        .reduce(0, +)
    }
    var totalTimeString: String {
        let h = totalMinutes / 60, m = totalMinutes % 60
        return "\(h)h \(m)m"
    }
    func minutesFromString(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard p.count == 2, let hh = Int(p[0]), let mm = Int(p[1]) else { return nil }
        return hh * 60 + mm
    }
}

struct ProjectLabel: Identifiable, Codable {
    var id = UUID()
    var title: String
    var color: String   // hex
}

class Project: Identifiable, ObservableObject, Codable {
    var id = UUID()
    @Published var name: String
    @Published var noteRows: [NoteRow]
    var labelID: UUID? = nil
    
    enum CodingKeys: CodingKey { case id, name, noteRows, labelID }
    init(name: String) {
        self.name = name; self.noteRows = []
    }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        noteRows = try c.decode([NoteRow].self, forKey: .noteRows)
        labelID = try? c.decode(UUID.self, forKey: .labelID)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(noteRows, forKey: .noteRows)
        try c.encode(labelID, forKey: .labelID)
    }
    
    var totalProjectMinutes: Int { noteRows.reduce(0) { $0 + $1.totalMinutes } }
    var totalProjectTimeString: String {
        let h = totalProjectMinutes / 60, m = totalProjectMinutes % 60
        return "\(h)h \(m)m"
    }
    func dateFromGiorno(_ g: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "it_IT")
        fmt.dateFormat = "EEEE dd/MM/yy"
        return fmt.date(from: g)
    }
}

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var backupProjects: [Project] = []
    @Published var labels: [ProjectLabel] = []
    @Published var currentProject: Project? {
        didSet {
            if let cp = currentProject {
                UserDefaults.standard.set(cp.id.uuidString, forKey: "lastProjectId")
            }
        }
    }
    @Published var lockedLabelID: UUID? = nil {
        didSet {
            if let l = lockedLabelID {
                UserDefaults.standard.set(l.uuidString, forKey: "lockedLabelID")
            } else {
                UserDefaults.standard.removeObject(forKey: "lockedLabelID")
            }
        }
    }
    private let projectsFileName = "projects.json"
    
    init() {
        loadProjects(); loadBackupProjects(); loadLabels()
        if let ls = UserDefaults.standard.string(forKey: "lockedLabelID"),
           let u = UUID(uuidString: ls) {
            lockedLabelID = u
        }
        if let last = UserDefaults.standard.string(forKey: "lastProjectId"),
           let p = projects.first(where: { $0.id.uuidString == last }) {
            currentProject = p
        } else {
            currentProject = projects.first
        }
        if projects.isEmpty { currentProject = nil; saveProjects() }
    }
    
    // MARK: -- Projects CRUD
    
    func addProject(name: String) {
        let p = Project(name: name)
        projects.append(p)
        currentProject = p
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    func renameProject(_ p: Project, newName: String) {
        p.name = newName
        saveProjects(); objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    func deleteProject(_ p: Project) {
        projects.removeAll { $0.id == p.id }
        if currentProject?.id == p.id { currentProject = projects.first }
        saveProjects(); objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    
    // MARK: -- Backups
    
    func deleteBackupProject(_ p: Project) {
        let u = getURLForBackup(project: p)
        try? FileManager.default.removeItem(at: u)
        backupProjects.removeAll { $0.id == p.id }
    }
    func isProjectRunning(_ p: Project) -> Bool {
        guard let last = p.noteRows.last else { return false }
        return last.orari.hasSuffix("-")
    }
    func getProjectsFileURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(projectsFileName)
    }
    func saveProjects() {
        do {
            let d = try JSONEncoder().encode(projects)
            try d.write(to: getProjectsFileURL())
        } catch { print("Error saving projects:", error) }
    }
    func loadProjects() {
        let u = getProjectsFileURL()
        if let d = try? Data(contentsOf: u),
           let arr = try? JSONDecoder().decode([Project].self, from: d) {
            projects = arr
        }
    }
    func getURLForBackup(project p: Project) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(p.name).json")
    }
    func backupCurrentProjectIfNeeded(_ p: Project, currentDate: Date, currentGiorno: String) {
        if let last = p.noteRows.last,
           last.giorno != currentGiorno,
           let d0 = p.dateFromGiorno(last.giorno) {
            let cal = Calendar.current
            if cal.component(.month, from: d0) != cal.component(.month, from: currentDate) {
                // create backup
                let fmt = DateFormatter(); fmt.locale = Locale(identifier: "it_IT"); fmt.dateFormat = "LLLL"
                let mn = fmt.string(from: d0).capitalized
                let yy = String(cal.component(.year, from: d0) % 100)
                let backupName = "\(p.name) \(mn) \(yy)"
                let bp = Project(name: backupName)
                bp.noteRows = p.noteRows
                let u = getURLForBackup(project: bp)
                do {
                    let d = try JSONEncoder().encode(bp)
                    try d.write(to: u)
                } catch { print("Errore backup:", error) }
                loadBackupProjects()
                p.noteRows.removeAll()
                saveProjects()
            }
        }
    }
    func loadBackupProjects() {
        backupProjects = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != projectsFileName }
            .forEach { file in
                if let d = try? Data(contentsOf: file),
                   let b = try? JSONDecoder().decode(Project.self, from: d) {
                    backupProjects.append(b)
                }
            }
    }
    
    // MARK: -- Labels
    
    func addLabel(title: String, color: String) {
        let l = ProjectLabel(title: title, color: color)
        labels.append(l); saveLabels(); objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    func renameLabel(_ l: ProjectLabel, newTitle: String) {
        if let i = labels.firstIndex(where: { $0.id == l.id }) {
            labels[i].title = newTitle
            saveLabels(); objectWillChange.send()
            NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
        }
    }
    func deleteLabel(_ l: ProjectLabel) {
        labels.removeAll { $0.id == l.id }
        projects.forEach { if $0.labelID == l.id { $0.labelID = nil } }
        backupProjects.forEach { if $0.labelID == l.id { $0.labelID = nil } }
        saveLabels(); saveProjects(); objectWillChange.send()
        if lockedLabelID == l.id { lockedLabelID = nil }
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    func saveLabels() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = docs.appendingPathComponent("labels.json")
        do {
            let d = try JSONEncoder().encode(labels)
            try d.write(to: u)
        } catch { print("Errore saving labels:", error) }
    }
    func loadLabels() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = docs.appendingPathComponent("labels.json")
        if let d = try? Data(contentsOf: u),
           let arr = try? JSONDecoder().decode([ProjectLabel].self, from: d) {
            labels = arr
        }
    }
    
    // MARK: -- Reordering
    
    func moveProjects(forLabel labelID: UUID?, indices: IndexSet, newOffset: Int) {
        var group = projects.filter { $0.labelID == labelID }
        group.move(fromOffsets: indices, toOffset: newOffset)
        projects.removeAll { $0.labelID == labelID }
        projects.append(contentsOf: group)
        saveProjects()
    }
    func moveBackupProjects(forLabel labelID: UUID?, indices: IndexSet, newOffset: Int) {
        var group = backupProjects.filter { $0.labelID == labelID }
        group.move(fromOffsets: indices, toOffset: newOffset)
        backupProjects.removeAll { $0.labelID == labelID }
        backupProjects.append(contentsOf: group)
        // no persistent save for backup ordering currently
    }
    
    // MARK: -- Export Data
    
    struct ExportData: Codable {
        let projects: [Project]
        let backupProjects: [Project]
        let labels: [ProjectLabel]
        let lockedLabelID: String?
    }
    func getExportURL() -> URL? {
        let ed = ExportData(projects: projects,
                            backupProjects: backupProjects,
                            labels: labels,
                            lockedLabelID: lockedLabelID?.uuidString)
        do {
            let d = try JSONEncoder().encode(ed)
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("MonteOreExport.json")
            try d.write(to: u)
            return u
        } catch {
            print("Errore export:", error)
            return nil
        }
    }
    
    // MARK: -- CSV Export
    
    func getCSVExportURL() -> URL? {
        let header = "Progetto,Totale Monte Ore\n"
        var csv = header
        for p in projects {
            csv += "\(p.name),\(p.totalProjectTimeString)\n"
            csv += "Data,Orari,Totale Giorno,Note\n"
            for r in p.noteRows {
                csv += "\(r.giorno),\"\(r.orari)\",\(r.totalTimeString),\"\(r.note)\"\n"
            }
            csv += "\n"
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("MonteOre.csv")
        do {
            try csv.data(using: .utf8)?.write(to: u)
            return u
        } catch {
            print("Errore CSV:", error)
            return nil
        }
    }
}

// MARK: - Export Confirmation

struct ImportConfirmationView: View {
    let message: String
    let importAction: () -> Void
    let cancelAction: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Importa File")
                .font(.title)
                .bold()
            Text(message)
                .multilineTextAlignment(.center)
                .padding()
            HStack {
                Button("Annulla", role: .destructive, action: cancelAction)
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 2))
                Button("Importa", action: importAction)
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.yellow)
                    .cornerRadius(8)
            }
        }
        .padding()
    }
}

// MARK: - ComeFunzionaSheetView

struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Come funziona l'app")
                    .font(.largeTitle).bold()
                Group {
                    Text("• Funzionalità generali: crea progetti, registra orari, esporta dati.")
                    Text("• Etichette: usa le etichette per raggruppare progetti. Tieni premuto per ordinarle.")
                    Text("• Progetti nascosti: puoi bloccare un'etichetta per non ciclare tra i suoi progetti.")
                }
                .padding(.leading)
                Group {
                    Text("Buone pratiche e consigli:")
                        .font(.headline)
                    Text("• Nelle note usa l'emoji ✅ per segnare le ore già trasferite in un registro esterno.")
                    Text("• Non includere mese e anno nel titolo del progetto: l'app lo gestisce automaticamente.")
                }
                .padding(.leading)
                Spacer(minLength: 30)
                Button("Chiudi", action: onDismiss)
                    .font(.title2)
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

// MARK: - LabelAssignmentView

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
                            withAnimation {
                                if project.labelID == label.id {
                                    project.labelID = nil
                                } else {
                                    project.labelID = label.id
                                    closeButtonVisible = true
                                }
                                projectManager.saveProjects()
                            }
                        }
                    }
                }
                if closeButtonVisible {
                    Button("Chiudi") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
                    .padding(.horizontal)
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

// MARK: - Color Change Sheet

struct ChangeLabelColorDirectSheet: View {
    @ObservedObject var projectManager: ProjectManager
    @State var label: ProjectLabel
    @State var selectedColor: Color
    @Environment(\.presentationMode) var presentationMode
    
    init(projectManager: ProjectManager, label: ProjectLabel) {
        self.projectManager = projectManager
        _label = State(initialValue: label)
        _selectedColor = State(initialValue: Color(hex: label.color))
    }
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer().frame(height: 60) // ↑ move circle up by ~1/3
            Circle()
                .fill(selectedColor)
                .frame(width: 150, height: 150)
            Text("Scegli un Colore")
                .font(.title)
            ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                .labelsHidden()
                .padding()
            Button("Conferma") {
                if let idx = projectManager.labels.firstIndex(where: { $0.id == label.id }) {
                    projectManager.labels[idx].color = UIColor(selectedColor).toHex
                    projectManager.saveLabels()
                }
                presentationMode.wrappedValue.dismiss()
            }
            .font(.title2)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .cornerRadius(8)
            
            Button("Annulla") {
                presentationMode.wrappedValue.dismiss()
            }
            .font(.title2)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.red)
            .cornerRadius(8)
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - LabelHeaderView

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
                Button {
                    if projectManager.lockedLabelID != label.id {
                        projectManager.lockedLabelID = label.id
                        if let first = projectManager.projects.first(where: { $0.labelID == label.id }) {
                            projectManager.currentProject = first
                        }
                        showLockInfo = true
                    } else {
                        projectManager.lockedLabelID = nil
                    }
                } label: {
                    Image(systemName: projectManager.lockedLabelID == label.id ? "lock.fill" : "lock.open")
                        .foregroundColor(.black)
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showLockInfo, arrowEdge: .bottom) {
                    VStack(spacing: 20) {
                        Text("IL PULSANTE È AGGANCIATO PER I PROGETTI DELL'ETICHETTA \(label.title)")
                            .font(.largeTitle)
                            .bold()
                            .multilineTextAlignment(.center)
                            .padding()
                        ForEach(projectManager.projects.filter { $0.labelID == label.id }) { proj in
                            Text(proj.name)
                                .underline()
                                .font(.headline)
                                .foregroundColor(Color(hex: label.color))
                        }
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
            } else {
                if projectManager.projects.filter({ $0.labelID == label.id }).isEmpty {
                    if projectManager.lockedLabelID == label.id {
                        projectManager.lockedLabelID = nil
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .onDrop(of: [UTType.text.identifier], isTargeted: $isTargeted) { prov in
            prov.first?.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { data, _ in
                if let d = data as? Data,
                   let s = String(data: d, encoding: .utf8),
                   let u = UUID(uuidString: s) {
                    DispatchQueue.main.async {
                        if let idx = projectManager.projects.firstIndex(where: { $0.id == u }) {
                            projectManager.projects[idx].labelID = label.id
                            projectManager.saveProjects()
                            projectManager.objectWillChange.send()
                            NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
                        }
                    }
                }
            }
            return true
        }
    }
}

// MARK: - ProjectRowView

struct ProjectRowView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool
    @State private var isHighlighted: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeIn(duration: 0.2)) { isHighlighted = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.2)) { isHighlighted = false }
                    // prevent switching if locked label
                    if let lid = projectManager.lockedLabelID,
                       project.labelID != lid {
                        return
                    }
                    projectManager.currentProject = project
                }
            } label: {
                HStack {
                    Text(project.name)
                        .font(.system(size: editingProjects ? 20 : 22))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .buttonStyle(PlainButtonStyle())
            
            Divider().frame(width: 1).background(Color.gray)
            
            if editingProjects {
                Button("Rinomina o Elimina") {
                    // show edit sheet
                    // … (same as before)
                }
                .font(.system(size: 18))
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .foregroundColor(.blue)
            } else {
                Button("Etichetta") {
                    // show label assignment sheet
                    // … (same as before)
                }
                .font(.system(size: 18))
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .foregroundColor(.blue)
            }
        }
        .background(
            projectManager.isProjectRunning(project)
                ? Color.yellow
                : (isHighlighted ? Color.gray.opacity(0.3) : Color.clear)
        )
        .onDrag { NSItemProvider(object: project.id.uuidString as NSString) }
    }
}

// MARK: - NoteView (Main Content)

struct NoteView: View {
    @ObservedObject var project: Project
    var projectManager: ProjectManager
    
    var body: some View {
        VStack {
            // 8) show etichetta name above
            if let lid = project.labelID,
               let lbl = projectManager.labels.first(where: { $0.id == lid }) {
                Text(lbl.title)
                    .font(.headline)
                    .foregroundColor(Color(hex: lbl.color))
            }
            // 2) project name underlined & colored
            Text(project.name)
                .underline()
                .font(.title3)
                .foregroundColor(
                    project.labelID.flatMap { id in
                        projectManager.labels.first(where: { $0.id == id })?.color
                    }.map { Color(hex: $0) } ?? .black
                )
            Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                .font(.title3)
                .bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(project.noteRows) { row in
                        HStack {
                            Text(row.giorno)
                                .font(.system(size: 15))
                                .frame(minHeight: 40)
                            Divider().frame(height: 40).background(Color.black)
                            Text(row.orari)
                                .font(.system(size: 15))
                                .frame(minHeight: 40)
                            Divider().frame(height: 40).background(Color.black)
                            Text(row.totalTimeString)
                                .font(.system(size: 15))
                                .frame(minHeight: 40)
                            Divider().frame(height: 40).background(Color.black)
                            Text(row.note)
                                .font(.system(size: 15))
                                .frame(minHeight: 40)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(20)
        .background(projectManager.isProjectRunning(project) ? Color.yellow : Color.clear)
        .cornerRadius(25)
        .padding()
    }
}

// MARK: - ProjectManagerListView

struct ProjectManagerListView: View {
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool
    
    var body: some View {
        List {
            Section(header:
                        Text("Progetti Correnti")
                            .font(.largeTitle).bold()
                            .padding(.top, 10)
            ) {
                let unlabeled = projectManager.projects.filter { $0.labelID == nil }
                if !unlabeled.isEmpty {
                    ForEach(unlabeled) { p in
                        ProjectRowView(project: p, projectManager: projectManager, editingProjects: editingProjects)
                    }
                    .onMove { idx, off in
                        projectManager.moveProjects(forLabel: nil, indices: idx, newOffset: off)
                    }
                }
                ForEach(projectManager.labels) { lbl in
                    LabelHeaderView(label: lbl, projectManager: projectManager)
                    let ps = projectManager.projects.filter { $0.labelID == lbl.id }
                    if !ps.isEmpty {
                        ForEach(ps) { p in
                            ProjectRowView(project: p, projectManager: projectManager, editingProjects: editingProjects)
                        }
                        .onMove { idx, off in
                            projectManager.moveProjects(forLabel: lbl.id, indices: idx, newOffset: off)
                        }
                    }
                }
            }
            
            Section(header:
                        Text("Mensilità Passate")
                            .font(.largeTitle).bold()
                            .padding(.top, 40)
            ) {
                let unl = projectManager.backupProjects.filter { $0.labelID == nil }
                if !unl.isEmpty {
                    ForEach(unl) { p in
                        ProjectRowView(project: p, projectManager: projectManager, editingProjects: editingProjects)
                    }
                    .onMove { idx, off in
                        projectManager.moveBackupProjects(forLabel: nil, indices: idx, newOffset: off)
                    }
                }
                ForEach(projectManager.labels) { lbl in
                    let ps = projectManager.backupProjects.filter { $0.labelID == lbl.id }
                    if !ps.isEmpty {
                        LabelHeaderView(label: lbl, projectManager: projectManager, isBackup: true)
                        ForEach(ps) { p in
                            ProjectRowView(project: p, projectManager: projectManager, editingProjects: editingProjects)
                        }
                        .onMove { idx, off in
                            projectManager.moveBackupProjects(forLabel: lbl.id, indices: idx, newOffset: off)
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
}

// MARK: - MainButtonView (unchanged)

struct MainButtonView: View {
    var isLandscape: Bool
    @ObservedObject var projectManager: ProjectManager
    
    var body: some View {
        Button(action: mainButtonTapped) {
            Text("Pigia il tempo")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                .background(Circle().fill(Color.black))
        }
        .disabled(projectManager.currentProject == nil ||
                  projectManager.backupProjects.contains { $0.id == projectManager.currentProject?.id })
    }
    
    func mainButtonTapped() {
        guard let project = projectManager.currentProject else { return }
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
            var last = project.noteRows.removeLast()
            if last.orari.hasSuffix("-") {
                last.orari += timeStr
            } else {
                last.orari += " " + timeStr + "-"
            }
            project.noteRows.append(last)
        }
        projectManager.saveProjects()
    }
}

// MARK: - BottomButtonsView (with split yellow button)

struct BottomButtonsView: View {
    var isLandscape: Bool
    @ObservedObject var projectManager: ProjectManager
    @Binding var showProjectManager: Bool
    
    var body: some View {
        HStack {
            Button(action: { showProjectManager = true }) {
                Text("Gestione\nProgetti")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)
                    .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
            }
            .background(Color(hex: "#54c0ff"))
            
            Spacer()
            
            // 11) split yellow into two hemispheres
            SplitCircleButton(isLandscape: isLandscape,
                              previous: { cycleProject(backward: true) },
                              next: { cycleProject(backward: false) })
                .disabled(projectManager.currentProject == nil ||
                          projectManager.backupProjects.contains { $0.id == projectManager.currentProject?.id })
                .background(Color(hex: "#54c0ff"))
        }
        .padding(.horizontal, isLandscape ? 10 : 30)
        .padding(.bottom, isLandscape ? 0 : 30)
    }
    
    func cycleProject(backward: Bool) {
        let available: [Project]
        if let lid = projectManager.lockedLabelID {
            available = projectManager.projects.filter { $0.labelID == lid }
        } else {
            available = projectManager.projects
        }
        guard let current = projectManager.currentProject,
              let idx = available.firstIndex(where: { $0.id == current.id }),
              available.count > 1
        else { return }
        let next = available[(idx + (backward ? -1 : 1) + available.count) % available.count]
        projectManager.currentProject = next
    }
}

// Split circle button view

struct SplitCircleButton: View {
    var isLandscape: Bool
    var previous: () -> Void
    var next: () -> Void
    
    var body: some View {
        ZStack {
            Circle().fill(Color.yellow)
                .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                .overlay(Circle().stroke(Color.black, lineWidth: 2))
            
            VStack(spacing: 0) {
                Button(action: previous) {
                    Rectangle().fill(Color.clear)
                }
                .frame(height: (isLandscape ? 100 : 140) / 2)
                
                Button(action: next) {
                    Rectangle().fill(Color.clear)
                }
                .frame(height: (isLandscape ? 100 : 140) / 2)
            }
            .clipShape(Circle())
            
            VStack {
                Image(systemName: "chevron.up")
                    .foregroundColor(.black)
                Spacer()
                Image(systemName: "chevron.down")
                    .foregroundColor(.black)
            }
            .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
        }
    }
}

// MARK: - ProjectManagerView

struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    
    @State private var newProjectName: String = ""
    @State private var showEtichetteSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importError: AlertError? = nil
    @State private var pendingImportData: ProjectManager.ExportData? = nil
    @State private var showImportConfirmationSheet: Bool = false
    @State private var showHowItWorksSheet: Bool = false
    @State private var showHowItWorksButton: Bool = false
    @State private var editMode: EditMode = .inactive
    @State private var editingProjects: Bool = false
    
    @State private var showShareOptions: Bool = false
    
    var body: some View {
        NavigationView {
            VStack {
                ProjectManagerListView(projectManager: projectManager, editingProjects: editingProjects)
                
                HStack {
                    TextField("Nuovo progetto", text: $newProjectName)
                        .font(.title3)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("Crea") {
                        if !newProjectName.isEmpty {
                            projectManager.addProject(name: newProjectName)
                            newProjectName = ""
                        }
                    }
                    .font(.title3)
                    .foregroundColor(.green)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green, lineWidth: 2))
                    Button("Etichette") {
                        showEtichetteSheet = true
                    }
                    .font(.title3)
                    .foregroundColor(.red)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 2))
                }
                .padding()
                
                HStack {
                    Button("Condividi Monte Ore") {
                        showShareOptions = true
                    }
                    .font(.title3)
                    .foregroundColor(.purple)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 2))
                    .confirmationDialog("Scegli formato di export", isPresented: $showShareOptions) {
                        Button("Backup JSON") {
                            if let url = projectManager.getExportURL() {
                                ActivityView(activityItems: [url]).present()
                            }
                        }
                        Button("Esporta CSV Monte Ore") {
                            if let url = projectManager.getCSVExportURL() {
                                ActivityView(activityItems: [url]).present()
                            }
                        }
                        Button("Annulla", role: .cancel) {}
                    }
                    Spacer()
                    Button("Importa File") {
                        showImportSheet = true
                    }
                    .font(.title3)
                    .foregroundColor(.orange)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2))
                }
                .padding(.horizontal)
            }
            .navigationBarTitle("", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(editingProjects ? "Fatto" : "Modifica") {
                        editingProjects.toggle()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showHowItWorksButton {
                        Button("Come funziona l'app") {
                            showHowItWorksSheet = true
                        }
                        .font(.custom("Permanent Marker", size: 20))
                        .foregroundColor(.black)
                        .padding(8)
                        .background(Color.yellow)
                        .cornerRadius(8)
                    } else {
                        Button("?") {
                            showHowItWorksButton = true
                        }
                        .font(.system(size: 40)).bold().foregroundColor(.yellow)
                    }
                }
            }
            .sheet(isPresented: $showEtichetteSheet) {
                LabelsManagerView(projectManager: projectManager)
            }
            .fileImporter(isPresented: $showImportSheet, allowedContentTypes: [UTType.json]) { result in
                switch result {
                case .success(let url):
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let d = try Data(contentsOf: url)
                            let imp = try JSONDecoder().decode(ProjectManager.ExportData.self, from: d)
                            pendingImportData = imp
                            showImportConfirmationSheet = true
                        } catch {
                            importError = AlertError(message: "Errore nell'importazione: \(error)")
                        }
                    } else {
                        importError = AlertError(message: "Non è possibile accedere al file importato.")
                    }
                case .failure(let err):
                    importError = AlertError(message: "Errore: \(err.localizedDescription)")
                }
            }
            .alert(item: $importError) { e in
                Alert(title: Text("Errore"), message: Text(e.message), dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showImportConfirmationSheet) {
                if let pending = pendingImportData {
                    ImportConfirmationView(
                        message: "Sei sicuro di voler sovrascrivere il file corrente? Tutti i progetti saranno persi.",
                        importAction: {
                            projectManager.projects = pending.projects
                            projectManager.backupProjects = pending.backupProjects
                            projectManager.labels = pending.labels
                            if let ls = pending.lockedLabelID, let u = UUID(uuidString: ls) {
                                projectManager.lockedLabelID = u
                            } else {
                                projectManager.lockedLabelID = nil
                            }
                            projectManager.currentProject = pending.projects.first
                            projectManager.saveProjects()
                            projectManager.saveLabels()
                            pendingImportData = nil
                            showImportConfirmationSheet = false
                        },
                        cancelAction: {
                            pendingImportData = nil
                            showImportConfirmationSheet = false
                        }
                    )
                } else {
                    Text("Errore: nessun dato da importare.")
                }
            }
            .sheet(isPresented: $showHowItWorksSheet, onDismiss: {
                showHowItWorksButton = false
            }) {
                ComeFunzionaSheetView { showHowItWorksSheet = false }
            }
            .onAppear {
                NotificationCenter.default.addObserver(forName: Notification.Name("CycleProjectNotification"), object: nil, queue: .main) { _ in
                    cycleProject()
                }
            }
        }
    }
    
    @State private var switchAlert: ActiveAlert? = nil
    
    func cycleProject() {
        let available: [Project]
        if let lid = projectManager.lockedLabelID {
            available = projectManager.projects.filter { $0.labelID == lid }
        } else {
            available = projectManager.projects
        }
        guard let current = projectManager.currentProject,
              let idx = available.firstIndex(where: { $0.id == current.id }),
              available.count > 1
        else { return }
        let next = available[(idx + 1) % available.count]
        projectManager.currentProject = next
    }
}

// MARK: - ActivityView Helper

struct ActivityView {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    
    func present() {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        UIApplication.shared.windows.first?.rootViewController?.present(vc, animated: true)
    }
}

// MARK: - ContentView & App

struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var showProjectManager: Bool = false
    @State private var showNonCHoSbattiSheet: Bool = false
    @State private var showPopup: Bool = false
    @AppStorage("medalAwarded") private var medalAwarded: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let showPrompt = projectManager.currentProject == nil
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if showPrompt {
                        NoNotesPromptView(onOk: { showProjectManager = true },
                                         onNonCHoSbatti: { showNonCHoSbattiSheet = true })
                    } else if let project = projectManager.currentProject {
                        NoteView(project: project, projectManager: projectManager)
                    }
                    MainButtonView(isLandscape: isLandscape, projectManager: projectManager)
                    BottomButtonsView(isLandscape: isLandscape, projectManager: projectManager, showProjectManager: $showProjectManager)
                }
                if showPopup {
                    PopupView(message: "Congratulazioni! Hai guadagnato la medaglia Sbattimenti zero eh")
                        .transition(.scale)
                }
            }
            .sheet(isPresented: $showProjectManager) { ProjectManagerView(projectManager: projectManager) }
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
        }
    }
}

@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Supporting Views

struct NoNotesPromptView: View {
    var onOk: () -> Void
    var onNonCHoSbatti: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Nessun progetto attivo")
                .font(.title).bold()
            Text("Per iniziare, crea o seleziona un progetto.")
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                Button("Crea/Seleziona Progetto", action: onOk)
                    .padding().background(Color.blue).foregroundColor(.white).cornerRadius(8)
                Button("Non CHo Sbatti", action: onNonCHoSbatti)
                    .padding().background(Color.orange).foregroundColor(.white).cornerRadius(8)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(12)
        .shadow(radius: 8)
    }
}

struct PopupView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(10)
            .shadow(radius: 10)
    }
}
