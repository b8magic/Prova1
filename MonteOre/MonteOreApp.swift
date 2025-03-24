import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Extensions

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

// MARK: - AlertError & ActiveAlert

struct AlertError: Identifiable {
    var id: String { message }
    let message: String
}

enum ActiveAlert: Identifiable {
    case running(newProject: Project, message: String)
    var id: String {
        switch self {
        case .running(let newProject, _):
            return newProject.id.uuidString
        }
    }
}

// MARK: - Data Models

struct NoteRow: Identifiable, Codable {
    var id = UUID()
    var giorno: String
    var orari: String
    var note: String = ""
    
    enum CodingKeys: String, CodingKey { case id, giorno, orari, note }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        giorno = try container.decode(String.self, forKey: .giorno)
        orari = try container.decode(String.self, forKey: .orari)
        note = (try? container.decode(String.self, forKey: .note)) ?? ""
    }
    init(giorno: String, orari: String, note: String = "") {
        self.giorno = giorno; self.orari = orari; self.note = note
    }
    var totalMinutes: Int {
        let segments = orari.split(separator: " ")
        var total = 0
        for seg in segments {
            let parts = seg.split(separator: "-")
            if parts.count == 2,
               let start = minutesFromString(String(parts[0])),
               let end = minutesFromString(String(parts[1])) {
                total += max(0, end - start)
            }
        }
        return total
    }
    var totalTimeString: String {
        let h = totalMinutes / 60, m = totalMinutes % 60
        return "\(h)h \(m)m"
    }
    func minutesFromString(_ timeStr: String) -> Int? {
        let parts = timeStr.split(separator: ":")
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) { return h * 60 + m }
        return nil
    }
}

struct ProjectLabel: Identifiable, Codable {
    var id = UUID()
    var title: String
    var color: String
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        noteRows = try container.decode([NoteRow].self, forKey: .noteRows)
        labelID = try? container.decode(UUID.self, forKey: .labelID)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(noteRows, forKey: .noteRows)
        try container.encode(labelID, forKey: .labelID)
    }
    var totalProjectMinutes: Int { noteRows.reduce(0) { $0 + $1.totalMinutes } }
    var totalProjectTimeString: String {
        let h = totalProjectMinutes / 60, m = totalProjectMinutes % 60
        return "\(h)h \(m)m"
    }
    func dateFromGiorno(_ giorno: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "it_IT")
        fmt.dateFormat = "EEEE dd/MM/yy"
        return fmt.date(from: giorno)
    }
}

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var backupProjects: [Project] = []
    @Published var labels: [ProjectLabel] = []
    
    @Published var currentProject: Project? {
        didSet { if let cp = currentProject { UserDefaults.standard.set(cp.id.uuidString, forKey: "lastProjectId") } }
    }
    
    // Solo nelle sezioni correnti (non backup) è possibile bloccare un'etichetta
    @Published var lockedLabelID: UUID? = nil {
        didSet {
            if let locked = lockedLabelID {
                UserDefaults.standard.set(locked.uuidString, forKey: "lockedLabelID")
            } else {
                UserDefaults.standard.removeObject(forKey: "lockedLabelID")
            }
        }
    }
    
    private let projectsFileName = "projects.json"
    
    init() {
        loadProjects()
        loadBackupProjects()
        loadLabels()
        if let lockedStr = UserDefaults.standard.string(forKey: "lockedLabelID"),
           let lockedUUID = UUID(uuidString: lockedStr) {
            lockedLabelID = lockedUUID
        }
        if let lastId = UserDefaults.standard.string(forKey: "lastProjectId"),
           let lastProject = projects.first(where: { $0.id.uuidString == lastId }) {
            currentProject = lastProject
        } else {
            currentProject = projects.first
        }
        if projects.isEmpty { currentProject = nil; saveProjects() }
    }
    
    // MARK: - Progetti
    func addProject(name: String) {
        let p = Project(name: name)
        projects.append(p)
        currentProject = p
        saveProjects()
    }
    func renameProject(project: Project, newName: String) {
        project.name = newName; saveProjects()
    }
    func deleteProject(project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: idx)
            if currentProject?.id == project.id { currentProject = projects.first }
            saveProjects()
        }
    }
    
    // MARK: - Backup
    func deleteBackupProject(project: Project) {
        let url = getURLForBackup(project: project)
        try? FileManager.default.removeItem(at: url)
        if let idx = backupProjects.firstIndex(where: { $0.id == project.id }) { backupProjects.remove(at: idx) }
    }
    func isProjectRunning(_ project: Project) -> Bool {
        if let lastRow = project.noteRows.last { return lastRow.orari.hasSuffix("-") }
        return false
    }
    func getProjectsFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(projectsFileName)
    }
    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: getProjectsFileURL())
        } catch { print("Error saving projects: \(error)") }
    }
    func loadProjects() {
        let url = getProjectsFileURL()
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved
        }
    }
    func getURLForBackup(project: Project) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("\(project.name).json")
    }
    func backupCurrentProjectIfNeeded(_ project: Project, currentDate: Date, currentGiorno: String) {
        if let lastRow = project.noteRows.last,
           lastRow.giorno != currentGiorno,
           let lastDate = project.dateFromGiorno(lastRow.giorno) {
            let cal = Calendar.current
            if cal.component(.month, from: lastDate) != cal.component(.month, from: currentDate) {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "it_IT")
                fmt.dateFormat = "LLLL"
                let monthName = fmt.string(from: lastDate).capitalized
                let yearSuffix = String(cal.component(.year, from: lastDate) % 100)
                let backupName = "\(project.name) \(monthName) \(yearSuffix)"
                let backupProj = Project(name: backupName)
                backupProj.noteRows = project.noteRows
                let url = getURLForBackup(project: backupProj)
                do {
                    let data = try JSONEncoder().encode(backupProj)
                    try data.write(to: url)
                    print("Backup creato in: \(url)")
                } catch { print("Errore backup: \(error)") }
                loadBackupProjects()
                project.noteRows.removeAll()
                saveProjects()
            }
        }
    }
    func loadBackupProjects() {
        backupProjects = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
            for file in files {
                if file.lastPathComponent != projectsFileName && file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let backup = try? JSONDecoder().decode(Project.self, from: data) {
                        backupProjects.append(backup)
                    }
                }
            }
        } catch { print("Errore loading backup: \(error)") }
    }
    
    // MARK: - Labels Management
    func addLabel(title: String, color: String) {
        let l = ProjectLabel(title: title, color: color)
        labels.append(l); saveLabels()
    }
    func renameLabel(label: ProjectLabel, newTitle: String) {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            labels[idx].title = newTitle; saveLabels()
        }
    }
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll(where: { $0.id == label.id })
        for p in projects { if p.labelID == label.id { p.labelID = nil } }
        saveLabels(); saveProjects()
        if lockedLabelID == label.id { lockedLabelID = nil }
    }
    func saveLabels() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("labels.json")
        do {
            let data = try JSONEncoder().encode(labels)
            try data.write(to: url)
        } catch { print("Errore saving labels: \(error)") }
    }
    func loadLabels() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("labels.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([ProjectLabel].self, from: data) {
            labels = saved
        }
    }
}

// MARK: - Export & Import

struct ExportData: Codable {
    let projects: [Project]
    let backupProjects: [Project]
    let labels: [ProjectLabel]
    let lockedLabelID: String?
}

extension ProjectManager {
    func getExportURL() -> URL? {
        let exportData = ExportData(
            projects: projects,
            backupProjects: backupProjects,
            labels: labels,
            lockedLabelID: lockedLabelID?.uuidString
        )
        do {
            let data = try JSONEncoder().encode(exportData)
            let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("MonteOreExport.json")
            try data.write(to: exportURL)
            return exportURL
        } catch { print("Errore export: \(error)"); return nil }
    }
}

// MARK: - Views

// NoNotesPromptView
struct NoNotesPromptView: View {
    let onOk: () -> Void
    let onNonCHoSbatti: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Dai, datti da fare!")
                .font(.custom("Permanent Marker", size: 36))
                .bold()
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
            Button(action: { onOk() }) {
                Text("Ok!")
                    .font(.custom("Permanent Marker", size: 24))
                    .bold()
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
            }
            Button(action: { onNonCHoSbatti() }) {
                Text("Non c'ho sbatti")
                    .font(.custom("Permanent Marker", size: 24))
                    .bold()
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(8)
            }
        }
        .padding()
    }
}

// LabelAssignmentView
struct LabelAssignmentView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    var body: some View {
        NavigationView {
            List {
                Button(action: {
                    project.labelID = nil
                    projectManager.saveProjects()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Text("Nessuna etichetta")
                        Spacer()
                        if project.labelID == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(projectManager.labels) { label in
                    Button(action: {
                        if project.labelID == label.id {
                            project.labelID = nil
                        } else {
                            project.labelID = label.id
                        }
                        projectManager.saveProjects()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Circle()
                                .fill(Color(hex: label.color))
                                .frame(width: 20, height: 20)
                            Text(label.title)
                            Spacer()
                            if project.labelID == label.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("Assegna Etichetta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// RenameLabelSheet (Tendina per rinominare etichetta)
struct RenameLabelSheet: View {
    @Binding var label: ProjectLabel
    @Binding var newName: String
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Rinomina Etichetta")
                .font(.title)
            TextField("Nuovo nome", text: $newName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
            Button(action: {
                label.title = newName
                onDismiss()
            }) {
                Text("Conferma")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
        .padding()
    }
}

// DeleteLabelSheet (Tendina per eliminare etichetta)
struct DeleteLabelSheet: View {
    let label: ProjectLabel
    var onDelete: () -> Void
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Elimina Etichetta")
                .font(.title).bold()
            Text("Sei sicuro di voler eliminare l'etichetta \"\(label.title)\"?")
                .multilineTextAlignment(.center)
                .padding()
            Button(action: { onDelete() }) {
                Text("Elimina")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(8)
            }
            Button(action: { onDismiss() }) {
                Text("Annulla")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray)
                    .cornerRadius(8)
            }
        }
        .padding()
    }
}

// ChangeLabelColorSheet (Tendina per cambiare colore)
struct ChangeLabelColorSheet: View {
    @Binding var label: ProjectLabel
    @Binding var selectedColor: Color
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Scegli un Colore")
                .font(.title)
            ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                .labelsHidden()
                .padding()
            Button(action: {
                label.color = UIColor(selectedColor).toHex
                onDismiss()
            }) {
                Text("Conferma")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
        .padding()
    }
}

// LabelsManagerView
struct LabelsManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newLabelTitle: String = ""
    @State private var newLabelColor: Color = .black
    // Tendine per etichette
    @State private var showRenameSheet: Bool = false
    @State private var showDeleteSheet: Bool = false
    @State private var showChangeColorSheet: Bool = false
    @State private var selectedLabel: ProjectLabel? = nil
    @State private var renameText: String = ""
    @State private var selectedColor: Color = .black
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels) { label in
                        HStack {
                            Button(action: {
                                selectedLabel = label
                                selectedColor = Color(hex: label.color)
                                showChangeColorSheet = true
                            }) {
                                Circle()
                                    .fill(Color(hex: label.color))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(PlainButtonStyle())
                            Text(label.title)
                            Spacer()
                            Button("Rinomina") {
                                selectedLabel = label
                                renameText = label.title
                                showRenameSheet = true
                            }
                            .foregroundColor(.blue)
                            Button("Elimina") {
                                selectedLabel = label
                                showDeleteSheet = true
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
                .listStyle(PlainListStyle())
                HStack {
                    TextField("Nuova etichetta", text: $newLabelTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    ColorPicker("", selection: $newLabelColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 50)
                    Button(action: {
                        if !newLabelTitle.isEmpty {
                            projectManager.addLabel(title: newLabelTitle, color: UIColor(newLabelColor).toHex)
                            newLabelTitle = ""
                            newLabelColor = .black
                        }
                    }) {
                        Text("Crea")
                            .foregroundColor(.green)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green, lineWidth: 2))
                    }
                }
                .padding()
            }
            .navigationTitle("Etichette")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showRenameSheet) {
                if let lbl = selectedLabel {
                    RenameLabelSheet(label: Binding(
                        get: { lbl },
                        set: { newVal in
                            if let idx = projectManager.labels.firstIndex(where: { $0.id == lbl.id }) {
                                projectManager.labels[idx] = newVal
                                projectManager.saveLabels()
                            }
                        }), newName: $renameText, onDismiss: {
                            showRenameSheet = false
                        })
                }
            }
            .sheet(isPresented: $showDeleteSheet) {
                if let lbl = selectedLabel {
                    DeleteLabelSheet(label: lbl, onDelete: {
                        projectManager.deleteLabel(label: lbl)
                        showDeleteSheet = false
                    }, onDismiss: { showDeleteSheet = false })
                }
            }
            .sheet(isPresented: $showChangeColorSheet) {
                if let lbl = selectedLabel {
                    ChangeLabelColorSheet(label: Binding(
                        get: { lbl },
                        set: { newVal in
                            if let idx = projectManager.labels.firstIndex(where: { $0.id == lbl.id }) {
                                projectManager.labels[idx] = newVal
                                projectManager.saveLabels()
                            }
                        }), selectedColor: $selectedColor, onDismiss: {
                            showChangeColorSheet = false
                        })
                }
            }
        }
    }
}

// ProjectRowView
struct ProjectRowView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @State private var showActionSheet: Bool = false
    @State private var showRenameSheet: Bool = false
    @State private var showLabelAssignSheet: Bool = false
    @State private var showDeleteSheet: Bool = false
    @State private var renameText: String = ""
    
    var body: some View {
        HStack {
            Text(project.name)
            Spacer()
            Button("Modifica") {
                showActionSheet = true
            }
            .foregroundColor(.blue)
            .actionSheet(isPresented: $showActionSheet) {
                ActionSheet(title: Text("Modifica Progetto"), buttons: [
                    .default(Text("Rinomina progetto"), action: {
                        renameText = project.name
                        showRenameSheet = true
                    }),
                    .default(Text("Applica o revoca etichetta"), action: {
                        showLabelAssignSheet = true
                    }),
                    .destructive(Text("Elimina progetto"), action: {
                        showDeleteSheet = true
                    }),
                    .cancel()
                ])
            }
            .sheet(isPresented: $showRenameSheet) {
                VStack(spacing: 20) {
                    Text("Rinomina Progetto").font(.title)
                    TextField("Nuovo nome", text: $renameText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    HStack(spacing: 40) {
                        Button("Annulla") { showRenameSheet = false }
                        Button("OK") {
                            projectManager.renameProject(project: project, newName: renameText)
                            showRenameSheet = false
                        }
                    }
                    .font(.title2)
                    Spacer()
                }
                .padding()
            }
            .sheet(isPresented: $showLabelAssignSheet) {
                LabelAssignmentView(project: project, projectManager: projectManager)
            }
            .sheet(isPresented: $showDeleteSheet) {
                DeleteConfirmationView(projectName: project.name) {
                    projectManager.deleteProject(project: project)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let locked = projectManager.lockedLabelID {
                if project.labelID == locked { projectManager.currentProject = project }
            } else {
                projectManager.currentProject = project
            }
        }
        .padding(.vertical, 4)
    }
}

// LabelHeaderView
struct LabelHeaderView: View {
    let label: ProjectLabel
    @ObservedObject var projectManager: ProjectManager
    var isBackup: Bool = false
    @State private var showLockInfo: Bool = false
    
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
            if !isBackup {
                if projectManager.lockedLabelID == nil || projectManager.lockedLabelID == label.id {
                    Button(action: {
                        if projectManager.lockedLabelID != label.id {
                            projectManager.lockedLabelID = label.id
                            if let first = projectManager.projects.first(where: { $0.labelID == label.id }) {
                                projectManager.currentProject = first
                            }
                            showLockInfo = true
                        } else {
                            projectManager.lockedLabelID = nil
                        }
                    }) {
                        Image(systemName: projectManager.lockedLabelID == label.id ? "lock.fill" : "lock.open")
                            .foregroundColor(.black)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showLockInfo, arrowEdge: .bottom) {
                        VStack(spacing: 20) {
                            Text("Il pulsante Giallo è agganciato ai progetti dell'etichetta \"\(label.title)\"")
                                .multilineTextAlignment(.center)
                                .padding()
                            Button(action: {
                                projectManager.lockedLabelID = nil
                                showLockInfo = false
                            }) {
                                Text("Chiudi")
                                    .foregroundColor(.white)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green)
                                    .cornerRadius(8)
                            }
                        }
                        .padding()
                        .frame(width: 300)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// ProjectManagerView
struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @State private var newProjectName: String = ""
    @State private var showEtichetteSheet: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importError: AlertError? = nil
    @State private var pendingImportData: ExportData? = nil
    @State private var showImportConfirmationSheet: Bool = false
    @State private var showHowItWorksSheet: Bool = false
    @State private var showHowItWorksButton: Bool = false
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header: Text("Progetti Correnti").font(.largeTitle).bold()) {
                        let currentUnlabeled = projectManager.projects.filter { $0.labelID == nil }
                        if !currentUnlabeled.isEmpty {
                            ForEach(currentUnlabeled) { project in
                                ProjectRowView(project: project, projectManager: projectManager)
                            }
                        }
                        ForEach(projectManager.labels) { label in
                            let projectsForLabel = projectManager.projects.filter { $0.labelID == label.id }
                            if !projectsForLabel.isEmpty {
                                LabelHeaderView(label: label, projectManager: projectManager, isBackup: false)
                                ForEach(projectsForLabel) { project in
                                    ProjectRowView(project: project, projectManager: projectManager)
                                }
                            }
                        }
                    }
                    Section(header: Text("Mensilità Passate").font(.largeTitle).bold()) {
                        let backupUnlabeled = projectManager.backupProjects.filter { $0.labelID == nil }
                        if !backupUnlabeled.isEmpty {
                            ForEach(backupUnlabeled) { project in
                                ProjectRowView(project: project, projectManager: projectManager)
                            }
                        }
                        ForEach(projectManager.labels) { label in
                            let backupForLabel = projectManager.backupProjects.filter { $0.labelID == label.id }
                            if !backupForLabel.isEmpty {
                                LabelHeaderView(label: label, projectManager: projectManager, isBackup: true)
                                ForEach(backupForLabel) { project in
                                    ProjectRowView(project: project, projectManager: projectManager)
                                }
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                HStack {
                    TextField("Nuovo progetto", text: $newProjectName)
                        .font(.title3)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        if !newProjectName.isEmpty {
                            projectManager.addProject(name: newProjectName)
                            newProjectName = ""
                        }
                    }) {
                        Text("Crea")
                            .font(.title3)
                            .foregroundColor(.green)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green, lineWidth: 2))
                    }
                    Button(action: { showEtichetteSheet = true }) {
                        Text("Etichette")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2))
                    }
                }
                .padding()
                HStack {
                    Button(action: { showShareSheet = true }) {
                        Text("Condividi Monte Ore")
                            .font(.title3)
                            .foregroundColor(.purple)
                            .padding()
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 2))
                    }
                    Spacer()
                    Button(action: { showImportSheet = true }) {
                        Text("Importa File")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .padding()
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2))
                    }
                }
                .padding(.horizontal)
            }
            .navigationBarTitle("", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showHowItWorksButton {
                        Button(action: {
                            showHowItWorksSheet = true
                        }) {
                            Text("Come funziona l'app")
                                .font(.custom("Permanent Marker", size: 20))
                                .foregroundColor(.black)
                                .padding(8)
                                .background(Color.yellow)
                                .cornerRadius(8)
                        }
                    } else {
                        Button(action: { showHowItWorksButton = true }) {
                            Text("?")
                                .font(.system(size: 40))
                                .bold()
                                .foregroundColor(.yellow)
                        }
                    }
                }
            }
            .sheet(isPresented: $showEtichetteSheet) {
                LabelsManagerView(projectManager: projectManager)
            }
            .sheet(isPresented: $showShareSheet) {
                if let exportURL = projectManager.getExportURL() {
                    ActivityView(activityItems: [exportURL])
                } else {
                    Text("Errore nell'esportazione")
                }
            }
            .fileImporter(isPresented: $showImportSheet, allowedContentTypes: [UTType.json]) { result in
                switch result {
                case .success(let url):
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let data = try Data(contentsOf: url)
                            let importedData = try JSONDecoder().decode(ExportData.self, from: data)
                            pendingImportData = importedData
                            showImportConfirmationSheet = true
                        } catch { importError = AlertError(message: "Errore nell'importazione: \(error)") }
                    } else {
                        importError = AlertError(message: "Non è possibile accedere al file importato.")
                    }
                case .failure(let error):
                    importError = AlertError(message: "Errore: \(error.localizedDescription)")
                }
            }
            .alert(item: $importError) { error in
                Alert(title: Text("Errore"), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showImportConfirmationSheet) {
                if let pending = pendingImportData {
                    ImportConfirmationView(
                        message: "Attenzione: sei sicuro di voler sovrascrivere il file corrente? Tutti i progetti saranno persi.",
                        importAction: {
                            projectManager.projects = pending.projects
                            projectManager.backupProjects = pending.backupProjects
                            projectManager.labels = pending.labels
                            if let lockedStr = pending.lockedLabelID, let uuid = UUID(uuidString: lockedStr) {
                                projectManager.lockedLabelID = uuid
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
            .sheet(isPresented: $showHowItWorksSheet, onDismiss: { showHowItWorksButton = false }) {
                ComeFunzionaSheetView { showHowItWorksSheet = false }
            }
        }
    }
}

// ComeFunzionaSheetView
struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack {
            Text("""
Se un'attività supera la mezzanotte, al momento di pigiarne il termine l'app creerà un nuovo giorno. Basterà modificare la nota col pulsante in alto a destra e inserire un termine di fine orario che fuoriesca le 24. Ad esempio, se l'attività si è conclusa all'1:29, si inserisca 25:29.

Ogni attività o task può avere una nota per differenziare tipologie di lavoro. Si consiglia di denominare le note "NomeProgetto NomeAttività".

L'uso dell'app è flessibile e adattabile alle proprie esigenze.
""")
                .multilineTextAlignment(.center)
                .padding()
                .font(.custom("Permanent Marker", size: 20))
            Button(action: { onDismiss() }) {
                Text("Chiudi")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
            }
        }
        .padding(30)
    }
}

// ActivityView
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                 applicationActivities: applicationActivities)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ContentView (Main)
struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var switchAlert: ActiveAlert? = nil
    @State private var showProjectManager: Bool = false
    @State private var showNonCHoSbattiSheet: Bool = false
    @State private var showPopup: Bool = false
    @AppStorage("medalAwarded") private var medalAwarded: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let showPrompt = projectManager.currentProject == nil
            let isBackupProject = projectManager.currentProject.flatMap {
                projectManager.backupProjects.first(where: { $0.id == $0.id })
            } != nil  // Semplificazione: considera il progetto di backup se presente
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if showPrompt {
                        NoNotesPromptView(onOk: { showProjectManager = true },
                                          onNonCHoSbatti: { showNonCHoSbattiSheet = true })
                    } else {
                        if let project = projectManager.currentProject {
                            ScrollView {
                                NoteView(project: project, projectManager: projectManager)
                                    .padding()
                            }
                            .frame(width: isLandscape ? geometry.size.width : geometry.size.width - 40,
                                   height: isLandscape ? geometry.size.height * 0.4 : geometry.size.height * 0.60)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(25)
                            .clipped()
                        }
                    }
                    Button(action: { mainButtonTapped() }) {
                        Text("Pigia il tempo")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                            .background(Circle().fill(Color.black))
                    }
                    .disabled(isBackupProject || projectManager.currentProject == nil)
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
                        Button(action: { cycleProject() }) {
                            Text("Cambia\nProgetto")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.black)
                                .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                                .background(Circle().fill(Color.yellow))
                                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        }
                        .background(Color(hex: "#54c0ff"))
                        .disabled(isBackupProject || projectManager.currentProject == nil)
                    }
                    .padding(.horizontal, isLandscape ? 10 : 30)
                    .padding(.bottom, isLandscape ? 0 : 30)
                }
                if showPopup {
                    PopupView(message: "Congratulazioni! Hai guadagnato la medaglia \"Sbattimenti zero eh\"")
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
            .alert(item: $switchAlert) { (alert: ActiveAlert) in
                switch alert {
                case .running(let newProject, let message):
                    return Alert(title: Text("Attenzione"),
                                 message: Text(message),
                                 primaryButton: .default(Text("Continua"), action: {
                        projectManager.currentProject = newProject
                    }),
                                 secondaryButton: .cancel())
                }
            }
        }
    }
    
    func cycleProject() {
        let available: [Project]
        if let locked = projectManager.lockedLabelID {
            available = projectManager.projects.filter { $0.labelID == locked }
        } else {
            available = projectManager.projects
        }
        guard let current = projectManager.currentProject,
              let idx = available.firstIndex(where: { $0.id == current.id }),
              available.count > 1 else { return }
        let next = available[(idx + 1) % available.count]
        if projectManager.isProjectRunning(current) {
            let running = available.filter { projectManager.isProjectRunning($0) }
            let names = running.map { $0.name }.joined(separator: ", ")
            let msg = "Attenzione: il tempo sta ancora scorrendo per i seguenti progetti: \(names). Vuoi continuare?"
            switchAlert = .running(newProject: next, message: msg)
        } else {
            projectManager.currentProject = next
        }
    }
    
    func mainButtonTapped() {
        guard let project = projectManager.currentProject else { playSound(success: false); return }
        if projectManager.backupProjects.contains(where: { $0.id == project.id }) { return }
        let now = Date()
        let df = DateFormatter(); df.locale = Locale(identifier: "it_IT")
        df.dateFormat = "EEEE dd/MM/yy"
        let giornoStr = df.string(from: now).capitalized
        let tf = DateFormatter(); tf.locale = Locale(identifier: "it_IT")
        tf.dateFormat = "HH:mm"
        let timeStr = tf.string(from: now)
        projectManager.backupCurrentProjectIfNeeded(project, currentDate: now, currentGiorno: giornoStr)
        if project.noteRows.isEmpty || project.noteRows.last?.giorno != giornoStr {
            let newRow = NoteRow(giorno: giornoStr, orari: timeStr + "-", note: "")
            project.noteRows.append(newRow)
        } else {
            guard var lastRow = project.noteRows.popLast() else { return }
            if lastRow.orari.hasSuffix("-") { lastRow.orari += timeStr }
            else { lastRow.orari += " " + timeStr + "-" }
            project.noteRows.append(lastRow)
        }
        projectManager.saveProjects()
        playSound(success: true)
    }
    
    func playSound(success: Bool) {
        // Implementa AVFoundation se desiderato
    }
}

// MARK: - ActivityView

struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                 applicationActivities: applicationActivities)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Main App

@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
