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
                  red: Double(r)/255,
                  green: Double(g)/255,
                  blue: Double(b)/255,
                  opacity: Double(a)/255)
    }
}

extension UIColor {
    var toHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}

// MARK: - Alerts

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

// MARK: - Data Models

struct NoteRow: Identifiable, Codable {
    var id = UUID()
    var giorno: String   // e.g. "Giovedì 18/03/25"
    var orari: String    // e.g. "14:32-17:12 17:18-"
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
    var color: String   // e.g. "#FF0000"
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
    
    // MARK: Projects
    
    func addProject(name: String) {
        let p = Project(name: name)
        projects.append(p)
        currentProject = p
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    
    func renameProject(project: Project, newName: String) {
        project.name = newName
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    
    func deleteProject(project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: idx)
            if currentProject?.id == project.id { currentProject = projects.first }
            saveProjects()
            objectWillChange.send()
            NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
        }
    }
    
    // MARK: Backup
    
    func deleteBackupProject(project: Project) {
        let url = getURLForBackup(project: project)
        try? FileManager.default.removeItem(at: url)
        if let idx = backupProjects.firstIndex(where: { $0.id == project.id }) {
            backupProjects.remove(at: idx)
        }
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
    
    // MARK: Labels Management
    
    func addLabel(title: String, color: String) {
        let l = ProjectLabel(title: title, color: color)
        labels.append(l)
        saveLabels()
        objectWillChange.send()
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
    }
    
    func renameLabel(label: ProjectLabel, newTitle: String) {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            labels[idx].title = newTitle
            saveLabels()
            objectWillChange.send()
            NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
        }
    }
    
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll(where: { $0.id == label.id })
        for p in projects { if p.labelID == label.id { p.labelID = nil } }
        for p in backupProjects { if p.labelID == label.id { p.labelID = nil } }
        saveLabels()
        saveProjects()
        objectWillChange.send()
        if lockedLabelID == label.id { lockedLabelID = nil }
        NotificationCenter.default.post(name: Notification.Name("CycleProjectNotification"), object: nil)
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
    
    // MARK: Reordering Projects per Group
    
    func moveProjects(forLabel labelID: UUID?, indices: IndexSet, newOffset: Int) {
        var group = projects.filter { $0.labelID == labelID }
        group.move(fromOffsets: indices, toOffset: newOffset)
        projects.removeAll { $0.labelID == labelID }
        projects.append(contentsOf: group)
    }
}

// MARK: ExportData

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

// MARK: ImportConfirmationView

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
                Button(action: { cancelAction() }) {
                    Text("Annulla")
                        .font(.title2)
                        .foregroundColor(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 2))
                }
                Button(action: { importAction() }) {
                    Text("Importa")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.yellow)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
    }
}

// MARK: ComeFunzionaSheetView

struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack {
            Text("""
Se un'attività supera la mezzanotte, al termine l'app creerà un nuovo giorno. Modifica la nota col pulsante in alto a destra e inserisci un orario oltre le 24 (es. 25:29) per registrare l'attività che si estende oltre la mezzanotte.
            
Ogni attività può avere una nota per differenziare tipologie di lavoro. Si consiglia di usare il formato: NomeProgetto NomeAttività.
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

// MARK: LabelAssignmentView

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
                            }
                            projectManager.saveProjects()
                        }
                    }
                }
                if closeButtonVisible {
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
            .navigationTitle("Assegna Etichetta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// MARK: ActivityView

struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: CombinedProjectEditSheet

struct CombinedProjectEditSheet: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newName: String
    @State private var showDeleteConfirmation = false
    init(project: Project, projectManager: ProjectManager) {
        self.project = project
        self.projectManager = projectManager
        _newName = State(initialValue: project.name)
    }
    var body: some View {
        VStack(spacing: 30) {
            VStack {
                Text("Rinomina")
                    .font(.headline)
                TextField("Nuovo nome", text: $newName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                Button(action: {
                    projectManager.renameProject(project: project, newName: newName)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Text("Conferma")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green)
                        .cornerRadius(8)
                }
            }
            Divider()
            VStack {
                Text("Elimina")
                    .font(.headline)
                Button(action: {
                    showDeleteConfirmation = true
                }) {
                    Text("Elimina")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(8)
                }
                .alert(isPresented: $showDeleteConfirmation) {
                    Alert(title: Text("Elimina progetto"),
                          message: Text("Sei sicuro di voler eliminare il progetto \(project.name) ?"),
                          primaryButton: .destructive(Text("Elimina"), action: {
                            projectManager.deleteProject(project: project)
                            presentationMode.wrappedValue.dismiss()
                          }),
                          secondaryButton: .cancel())
                }
            }
        }
        .padding()
    }
}

// MARK: ProjectEditToggleButton

struct ProjectEditToggleButton: View {
    @Binding var isEditing: Bool
    var body: some View {
        Button(action: { isEditing.toggle() }) {
            Text(isEditing ? "Fatto" : "Modifica")
                .font(.headline)
                .padding(8)
                .foregroundColor(.blue)
        }
    }
}

// MARK: ProjectRowView

struct ProjectRowView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool
    @State private var isHighlighted: Bool = false
    @State private var showSecondarySheet = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeIn(duration: 0.2)) { isHighlighted = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.2)) { isHighlighted = false }
                    projectManager.currentProject = project
                }
            }) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .buttonStyle(PlainButtonStyle())
            Divider().frame(width: 1).background(Color.gray)
            Button(action: { showSecondarySheet = true }) {
                Text(editingProjects ? "Rinomina o Elimina" : "Etichetta")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }
        }
        .background(isHighlighted ? Color.gray.opacity(0.3) : Color.clear)
        .sheet(isPresented: $showSecondarySheet) {
            if editingProjects {
                CombinedProjectEditSheet(project: project, projectManager: projectManager)
            } else {
                LabelAssignmentView(project: project, projectManager: projectManager)
            }
        }
        .onDrag { NSItemProvider(object: project.id.uuidString as NSString) }
    }
}

// MARK: NoteView (Main Content)

struct NoteView: View {
    @ObservedObject var project: Project
    var projectManager: ProjectManager
    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(project.name)
                        .font(.title3)
                    Spacer()
                    Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                        .font(.title3)
                        .bold()
                }
                .padding(.bottom, 5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(project.noteRows) { row in
                            HStack {
                                Text(row.giorno)
                                    .font(.system(size: 17))
                                    .frame(minHeight: 60)
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.orari)
                                    .font(.system(size: 17))
                                    .frame(minHeight: 60)
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.totalTimeString)
                                    .font(.system(size: 17))
                                    .frame(minHeight: 60)
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.note)
                                    .font(.system(size: 17))
                                    .frame(minHeight: 60)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(20)
        }
        .background(projectManager.isProjectRunning(project) ? Color.yellow : Color.clear)
        .cornerRadius(25)
        .padding()
    }
}

// MARK: LabelHeaderView

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
                        Text("IL PULSANTE È AGGANCIO PER I PROGETTI DELL'ETICHETTA \(label.title)")
                            .font(.title)
                            .bold()
                            .multilineTextAlignment(.center)
                            .padding()
                        ForEach(projectManager.projects.filter { $0.labelID == label.id }) { proj in
                            Text(proj.name)
                                .underline()
                                .foregroundColor({
                                    if let lbl = projectManager.labels.first(where: { $0.id == proj.labelID }) {
                                        return Color(hex: lbl.color)
                                    }
                                    return .black
                                }())
                                .font(.headline)
                        }
                        Button(action: { showLockInfo = false }) {
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
        .onDrop(of: [UTType.text.identifier], isTargeted: $isTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { (data, error) in
                if let data = data as? Data,
                   let idString = String(data: data, encoding: .utf8),
                   let uuid = UUID(uuidString: idString) {
                    DispatchQueue.main.async {
                        if let index = projectManager.projects.firstIndex(where: { $0.id == uuid }) {
                            projectManager.projects[index].labelID = label.id
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

// MARK: LabelsManagerView and Wrappers

enum LabelActionType: Identifiable {
    case rename(label: ProjectLabel, initialText: String)
    case delete(label: ProjectLabel)
    case changeColor(label: ProjectLabel)
    var id: UUID {
        switch self {
        case .rename(let label, _): return label.id
        case .delete(let label): return label.id
        case .changeColor(let label): return label.id
        }
    }
}

struct LabelsManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newLabelTitle: String = ""
    @State private var newLabelColor: Color = .black
    @State private var activeLabelAction: LabelActionType? = nil
    @State private var isEditingLabels: Bool = false
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels) { label in
                        HStack(spacing: 12) {
                            Button(action: { activeLabelAction = .changeColor(label: label) }) {
                                Circle()
                                    .fill(Color(hex: label.color))
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(PlainButtonStyle())
                            Text(label.title)
                            Spacer()
                            Button("Rinomina") {
                                activeLabelAction = .rename(label: label, initialText: label.title)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.blue)
                            Button("Elimina") {
                                activeLabelAction = .delete(label: label)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.red)
                        }
                        .contentShape(Rectangle())
                    }
                    .onMove { indices, newOffset in
                        projectManager.labels.move(fromOffsets: indices, toOffset: newOffset)
                        projectManager.saveLabels()
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
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isEditingLabels.toggle() }) {
                        Text(isEditingLabels ? "Fatto" : "Ordina")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                }
            }
            .environment(\.editMode, .constant(isEditingLabels ? EditMode.active : EditMode.inactive))
            .sheet(item: $activeLabelAction) { action in
                switch action {
                case .rename(let label, let initialText):
                    RenameLabelSheetWrapper(projectManager: projectManager, label: label, initialText: initialText) {
                        activeLabelAction = nil
                    }
                case .delete(let label):
                    DeleteLabelSheetWrapper(projectManager: projectManager, label: label) {
                        activeLabelAction = nil
                    }
                case .changeColor(let label):
                    ChangeLabelColorDirectSheet(projectManager: projectManager, label: label) {
                        activeLabelAction = nil
                    }
                }
            }
        }
    }
}

struct RenameLabelSheetWrapper: View {
    @ObservedObject var projectManager: ProjectManager
    @State var label: ProjectLabel
    @State var newName: String
    var onDismiss: () -> Void
    init(projectManager: ProjectManager, label: ProjectLabel, initialText: String, onDismiss: @escaping () -> Void) {
        self.projectManager = projectManager
        _label = State(initialValue: label)
        _newName = State(initialValue: initialText)
        self.onDismiss = onDismiss
    }
    var body: some View {
        VStack(spacing: 20) {
            Text("Rinomina Etichetta")
                .font(.title)
            TextField("Nuovo nome", text: $newName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
            Button(action: {
                projectManager.renameLabel(label: label, newTitle: newName)
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

struct DeleteLabelSheetWrapper: View {
    @ObservedObject var projectManager: ProjectManager
    var label: ProjectLabel
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Elimina Etichetta")
                .font(.title)
                .bold()
            Text("Sei sicuro di voler eliminare l'etichetta \(label.title) ?")
                .multilineTextAlignment(.center)
                .padding()
            Button(action: {
                projectManager.deleteLabel(label: label)
                onDismiss()
            }) {
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

struct ChangeLabelColorDirectSheet: View {
    @ObservedObject var projectManager: ProjectManager
    @State var label: ProjectLabel
    @State var selectedColor: Color
    var onDismiss: () -> Void
    init(projectManager: ProjectManager, label: ProjectLabel, onDismiss: @escaping () -> Void) {
        self.projectManager = projectManager
        _label = State(initialValue: label)
        _selectedColor = State(initialValue: Color(hex: label.color))
        self.onDismiss = onDismiss
    }
    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .fill(selectedColor)
                .frame(width: 150, height: 150)
                .padding(.top, 40)
            Text("Scegli un Colore")
                .font(.title)
            ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                .labelsHidden()
                .padding()
            Button(action: {
                if let idx = projectManager.labels.firstIndex(where: { $0.id == label.id }) {
                    projectManager.labels[idx].color = UIColor(selectedColor).toHex
                    projectManager.saveLabels()
                }
                onDismiss()
            }) {
                Text("Conferma")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
            }
            Button(action: { onDismiss() }) {
                Text("Annulla")
                    .font(.title2)
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

// MARK: - ProjectManagerListView (Extracted List Subview)

struct ProjectManagerListView: View {
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool
    var body: some View {
        List {
            Section(header:
                        Text("Progetti Correnti")
                            .font(.largeTitle)
                            .bold()
                            .padding(.top, 10)) {
                let unlabeled = projectManager.projects.filter { $0.labelID == nil }
                if !unlabeled.isEmpty {
                    ForEach(unlabeled) { project in
                        ProjectRowView(project: project, projectManager: projectManager, editingProjects: editingProjects)
                    }
                    .onMove { indices, newOffset in
                        projectManager.moveProjects(forLabel: nil, indices: indices, newOffset: newOffset)
                    }
                }
                ForEach(projectManager.labels) { label in
                    LabelHeaderView(label: label, projectManager: projectManager, isBackup: false)
                    let projectsForLabel = projectManager.projects.filter { $0.labelID == label.id }
                    if !projectsForLabel.isEmpty {
                        ForEach(projectsForLabel) { project in
                            ProjectRowView(project: project, projectManager: projectManager, editingProjects: editingProjects)
                        }
                        .onMove { indices, newOffset in
                            projectManager.moveProjects(forLabel: label.id, indices: indices, newOffset: newOffset)
                        }
                    }
                }
            }
            Section(header:
                        Text("Mensilità Passate")
                            .font(.largeTitle)
                            .bold()
                            .padding(.top, 40)) {
                let unlabeled = projectManager.backupProjects.filter { $0.labelID == nil }
                if !unlabeled.isEmpty {
                    ForEach(unlabeled) { project in
                        ProjectRowView(project: project, projectManager: projectManager, editingProjects: editingProjects)
                    }
                }
                ForEach(projectManager.labels) { label in
                    let backupForLabel = projectManager.backupProjects.filter { $0.labelID == label.id }
                    if !backupForLabel.isEmpty {
                        LabelHeaderView(label: label, projectManager: projectManager, isBackup: true)
                        ForEach(backupForLabel) { project in
                            ProjectRowView(project: project, projectManager: projectManager, editingProjects: editingProjects)
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
}

// MARK: - ProjectManagerView

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
    @State private var editMode: EditMode = .inactive
    @State private var editingProjects: Bool = false
    var body: some View {
        NavigationView {
            VStack {
                ProjectManagerListView(projectManager: projectManager, editingProjects: editingProjects)
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
                            .foregroundColor(.red)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 2))
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
                ToolbarItem(placement: .navigationBarLeading) {
                    ProjectEditToggleButton(isEditing: $editingProjects)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showHowItWorksButton {
                        Button(action: { showHowItWorksSheet = true }) {
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
            .sheet(isPresented: $showEtichetteSheet) { LabelsManagerView(projectManager: projectManager) }
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
        if let locked = projectManager.lockedLabelID {
            available = projectManager.projects.filter { $0.labelID == locked }
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
    
    func mainButtonTapped() {
        guard let project = projectManager.currentProject else {
            playSound(success: false)
            return
        }
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
        // Implement AVFoundation if desired
    }
}

// MARK: - NoNotesPromptView, PopupView, NonCHoSbattiSheetView

struct NoNotesPromptView: View {
    var onOk: () -> Void
    var onNonCHoSbatti: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Nessun progetto attivo")
                .font(.title)
                .bold()
            Text("Per iniziare, crea o seleziona un progetto.")
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                Button(action: onOk) {
                    Text("Crea/Seleziona Progetto")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                Button(action: onNonCHoSbatti) {
                    Text("Non CHo Sbatti")
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
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

struct NonCHoSbattiSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Frate, nemmeno io...")
                .font(.custom("Permanent Marker", size: 28))
                .bold()
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
            Button(action: { onDismiss() }) {
                Text("Mh")
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

// MARK: - ContentView (Main)

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
            let isBackupProject = projectManager.currentProject.flatMap { proj in
                projectManager.backupProjects.first(where: { $0.id == proj.id })
            } != nil
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if showPrompt {
                        NoNotesPromptView(onOk: { showProjectManager = true },
                                          onNonCHoSbatti: { showNonCHoSbattiSheet = true })
                    } else {
                        if let project = projectManager.currentProject {
                            NoteView(project: project, projectManager: projectManager)
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
    
    func cycleProject() {
        let available: [Project]
        if let locked = projectManager.lockedLabelID {
            available = projectManager.projects.filter { $0.labelID == locked }
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
    
    func mainButtonTapped() {
        guard let project = projectManager.currentProject else {
            playSound(success: false)
            return
        }
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
        // Implement AVFoundation if desired
    }
}

// MARK: - App Main

@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
