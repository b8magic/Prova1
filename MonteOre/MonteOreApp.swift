import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Color Extensions
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255,
                            (int >> 8) * 17,
                            (int >> 4 & 0xF) * 17,
                            (int & 0xF) * 17)
        case 6: // RRGGBB (24-bit)
            (a, r, g, b) = (255,
                            int >> 16,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        case 8: // AARRGGBB (32-bit)
            (a, r, g, b) = (int >> 24,
                            int >> 16 & 0xFF,
                            int >> 8 & 0xFF,
                            int & 0xFF)
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
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r*255), Int(g*255), Int(b*255))
    }
}

// MARK: - Alert Structures
struct AlertError: Identifiable {
    var id: String { message }
    let message: String
}
enum ActiveAlert: Identifiable {
    case running(newProject: Project, message: String)
    var id: String {
        switch self {
        case .running(let np, _): return np.id.uuidString
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

    init(giorno: String, orari: String, note: String = "") {
        self.giorno = giorno; self.orari = orari; self.note = note
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id     = try c.decode(UUID.self, forKey: .id)
        giorno = try c.decode(String.self, forKey: .giorno)
        orari  = try c.decode(String.self, forKey: .orari)
        note   = (try? c.decode(String.self, forKey: .note)) ?? ""
    }

    var totalMinutes: Int {
        orari.split(separator: " ").reduce(0) { sum, seg in
            let parts = seg.split(separator: "-")
            guard parts.count == 2,
                  let s = minutes(from: String(parts[0])),
                  let e = minutes(from: String(parts[1])) else {
                return sum
            }
            return sum + max(0, e - s)
        }
    }
    var totalTimeString: String {
        let h = totalMinutes / 60, m = totalMinutes % 60
        return "\(h)h \(m)m"
    }
    private func minutes(from str: String) -> Int? {
        let p = str.split(separator: ":")
        guard p.count == 2,
              let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h*60 + m
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
        self.name = name
        self.noteRows = []
    }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        name     = try c.decode(String.self, forKey: .name)
        noteRows = try c.decode([NoteRow].self, forKey: .noteRows)
        labelID  = try? c.decode(UUID.self, forKey: .labelID)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id,       forKey: .id)
        try c.encode(name,     forKey: .name)
        try c.encode(noteRows, forKey: .noteRows)
        try c.encode(labelID,  forKey: .labelID)
    }

    var totalProjectMinutes: Int {
        noteRows.reduce(0) { $0 + $1.totalMinutes }
    }
    var totalProjectTimeString: String {
        let h = totalProjectMinutes / 60, m = totalProjectMinutes % 60
        return "\(h)h \(m)m"
    }
    func dateFromGiorno(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale     = Locale(identifier: "it_IT")
        fmt.dateFormat = "EEEE dd/MM/yy"
        return fmt.date(from: s)
    }
}

// MARK: - ProjectManager
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
    private let backupOrderFileName = "backupOrder.json"

    init() {
        loadProjects()
        loadBackupProjects()
        loadBackupOrder()
        loadLabels()
        cleanupEmptyLock()

        if let s = UserDefaults.standard.string(forKey: "lockedLabelID"),
           let u = UUID(uuidString: s) {
            lockedLabelID = u
        }
        if let s = UserDefaults.standard.string(forKey: "lastProjectId"),
           let p = projects.first(where: { $0.id.uuidString == s }) {
            currentProject = p
        } else {
            currentProject = projects.first
        }
        if projects.isEmpty {
            currentProject = nil
            saveProjects()
        }
    }

    // MARK: Projects
    func addProject(name: String) {
        let p = Project(name: name)
        projects.append(p)
        currentProject = p
        saveProjects()
        postCycleNotification()
    }
    func renameProject(project: Project, newName: String) {
        project.name = newName
        saveProjects()
        postCycleNotification()
    }
    func deleteProject(project: Project) {
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: i)
            if currentProject?.id == project.id {
                currentProject = projects.first
            }
            saveProjects()
            postCycleNotification()
        }
    }

    // MARK: Backup
    func deleteBackupProject(project: Project) {
        let url = getURLForBackup(project: project)
        try? FileManager.default.removeItem(at: url)
        if let i = backupProjects.firstIndex(where: { $0.id == project.id }) {
            backupProjects.remove(at: i)
            saveBackupOrder()
        }
    }
    func isProjectRunning(_ project: Project) -> Bool {
        project.noteRows.last?.orari.hasSuffix("-") ?? false
    }

    func getProjectsFileURL() -> URL {
        FileManager.default
          .urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent(projectsFileName)
    }
    func saveProjects() {
        do {
            let d = try JSONEncoder().encode(projects)
            try d.write(to: getProjectsFileURL())
        } catch {
            print("Error saving projects:", error)
        }
    }
    func loadProjects() {
        let url = getProjectsFileURL()
        if let d = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([Project].self, from: d) {
            projects = arr
        }
    }

    func getURLForBackup(project: Project) -> URL {
        FileManager.default
          .urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("\(project.name).json")
    }
    func backupCurrentProjectIfNeeded(
      _ project: Project,
      currentDate: Date,
      currentGiorno: String
    ) {
        guard let last = project.noteRows.last,
              last.giorno != currentGiorno,
              let d = project.dateFromGiorno(last.giorno)
        else { return }

        let cal = Calendar.current
        if cal.component(.month, from: d) !=
           cal.component(.month, from: currentDate)
        {
            let fmt = DateFormatter()
            fmt.locale     = Locale(identifier: "it_IT")
            fmt.dateFormat = "LLLL"
            let m = fmt.string(from: d).capitalized
            let y = String(cal.component(.year, from: d) % 100)
            let name = "\(project.name) \(m) \(y)"
            let backup = Project(name: name)
            backup.noteRows = project.noteRows

            let url = getURLForBackup(project: backup)
            do {
                let d = try JSONEncoder().encode(backup)
                try d.write(to: url)
            } catch {
                print("Errore backup:", error)
            }
            loadBackupProjects()
            saveBackupOrder()
            project.noteRows.removeAll()
            saveProjects()
        }
    }

    func loadBackupProjects() {
        backupProjects = []
        let docs = FileManager.default
                   .urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(
                             at: docs,
                             includingPropertiesForKeys: nil)
        {
            for file in files {
                if file.lastPathComponent != projectsFileName
                   && file.pathExtension == "json"
                   && file.lastPathComponent != backupOrderFileName
                {
                    if var p = try? JSONDecoder().decode(
                                  Project.self,
                                  from: Data(contentsOf: file))
                    {
                        p.id = UUID()
                        backupProjects.append(p)
                    }
                }
            }
        }
    }

    func saveBackupOrder() {
        let order = backupProjects.map { $0.id.uuidString }
        let url = FileManager.default
                  .urls(for: .documentDirectory, in: .userDomainMask)[0]
                  .appendingPathComponent(backupOrderFileName)
        if let d = try? JSONEncoder().encode(order) {
            try? d.write(to: url)
        }
    }

    func loadBackupOrder() {
        let url = FileManager.default
                  .urls(for: .documentDirectory, in: .userDomainMask)[0]
                  .appendingPathComponent(backupOrderFileName)
        if let d = try? Data(contentsOf: url),
           let order = try? JSONDecoder().decode([String].self, from: d)
        {
            var ordered: [Project] = []
            for idStr in order {
                if let uuid = UUID(uuidString: idStr),
                   let proj = backupProjects.first(where: { $0.id == uuid }) {
                    ordered.append(proj)
                }
            }
            for p in backupProjects where !ordered.contains(where: { $0.id == p.id }) {
                ordered.append(p)
            }
            backupProjects = ordered
        }
    }

    // MARK: Labels
    func addLabel(title: String, color: String) {
        let l = ProjectLabel(title: title, color: color)
        labels.append(l)
        saveLabels()
        postCycleNotification()
    }
    func renameLabel(label: ProjectLabel, newTitle: String) {
        if let i = labels.firstIndex(where: { $0.id == label.id }) {
            labels[i].title = newTitle
            saveLabels()
            postCycleNotification()
        }
    }
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll(where: { $0.id == label.id })
        for p in projects    where p.labelID == label.id { p.labelID = nil }
        for p in backupProjects where p.labelID == label.id { p.labelID = nil }
        saveLabels()
        saveProjects()
        saveBackupOrder()
        cleanupEmptyLock()
        postCycleNotification()
    }
    func saveLabels() {
        let url = FileManager.default
                   .urls(for: .documentDirectory, in: .userDomainMask)[0]
                   .appendingPathComponent("labels.json")
        if let d = try? JSONEncoder().encode(labels) {
            try? d.write(to: url)
        }
    }
    func loadLabels() {
        let url = FileManager.default
                   .urls(for: .documentDirectory, in: .userDomainMask)[0]
                   .appendingPathComponent("labels.json")
        if let d = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([ProjectLabel].self, from: d)
        {
            labels = arr
        }
    }

    func saveBackupProjects() {
        for p in backupProjects {
            let url = getURLForBackup(project: p)
            if let d = try? JSONEncoder().encode(p) {
                try? d.write(to: url)
            }
        }
    }

    // MARK: Reordering
    func moveProjects(forLabel labelID: UUID?,
                      indices: IndexSet,
                      newOffset: Int)
    {
        var g = projects.filter { $0.labelID == labelID }
        g.move(fromOffsets: indices, toOffset: newOffset)
        projects.removeAll { $0.labelID == labelID }
        projects.append(contentsOf: g)
        saveProjects()
        cleanupEmptyLock()
    }
    func moveBackupProjects(forLabel labelID: UUID?,
                            indices: IndexSet,
                            newOffset: Int)
    {
        var g = backupProjects.filter { $0.labelID == labelID }
        g.move(fromOffsets: indices, toOffset: newOffset)
        backupProjects.removeAll { $0.labelID == labelID }
        backupProjects.append(contentsOf: g)
        saveBackupOrder()
    }

    // MARK: Exports
    struct ExportData: Codable {
        let projects: [Project]
        let backupProjects: [Project]
        let labels: [ProjectLabel]
        let lockedLabelID: String?
    }
    func getExportURL() -> URL? {
        let d = ExportData(
          projects: projects,
          backupProjects: backupProjects,
          labels: labels,
          lockedLabelID: lockedLabelID?.uuidString)
        if let data = try? JSONEncoder().encode(d) {
            let url = FileManager.default.temporaryDirectory
                      .appendingPathComponent("MonteOreExport.json")
            try? data.write(to: url)
            return url
        }
        return nil
    }
    func getCSVExportURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
                  .appendingPathComponent("MonteOreExport.txt")
        var txt = ""
        for p in projects {
            txt += "\"\(p.name)\",\"\(p.totalProjectTimeString)\"\n"
            for r in p.noteRows {
                txt += "\(r.giorno),\"\(r.orari)\",\"\(r.totalTimeString)\",\"\(r.note)\"\n"
            }
            txt += "\n"
        }
        try? txt.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Helpers
    private func postCycleNotification() {
        NotificationCenter.default.post(
          name: Notification.Name("CycleProjectNotification"),
          object: nil)
    }
    private func cleanupEmptyLock() {
        if let lid = lockedLabelID {
            let has = projects.contains { $0.labelID == lid }
            if !has {
                lockedLabelID = nil
                currentProject = projects.first
            }
        }
    }
}

// MARK: - ActivityView
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(
      context: Context) -> UIActivityViewController
    {
        UIActivityViewController(
          activityItems: activityItems,
          applicationActivities: applicationActivities)
    }
    func updateUIViewController(
      _ vc: UIActivityViewController,
      context: Context) {}
}

// MARK: - LabelAssignmentView
struct LabelAssignmentView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var closeVisible = false

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
                                    closeVisible = true
                                }
                            }
                            projectManager.saveProjects()
                            projectManager.objectWillChange.send()
                            projectManager.cleanupEmptyLock()
                        }
                    }
                }
                if closeVisible {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Chiudi")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .cornerRadius(8)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Assegna Etichetta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }
}

// MARK: - CombinedProjectEditSheet
struct CombinedProjectEditSheet: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newName: String
    @State private var showDelete = false

    init(project: Project, projectManager: ProjectManager) {
        self.project = project
        self.projectManager = projectManager
        _newName = State(initialValue: project.name)
    }

    var body: some View {
        VStack(spacing: 30) {
            VStack {
                Text("Rinomina").font(.headline)
                TextField("Nuovo nome", text: $newName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                Button(action: {
                    if projectManager.backupProjects.contains(where: {
                        $0.id == project.id }) {
                        let old = project.name
                        project.name = newName
                        projectManager.deleteBackupProject(project: Project(name: old))
                        projectManager.backupProjects.removeAll(where: { $0.name == old })
                        projectManager.backupProjects.append(project)
                        let url = projectManager.getURLForBackup(project: project)
                        if let d = try? JSONEncoder().encode(project) {
                            try? d.write(to: url)
                        }
                    } else {
                        projectManager.renameProject(project: project,
                                                     newName: newName)
                    }
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
                .contentShape(Rectangle())
            }

            Divider()

            VStack {
                Text("Elimina").font(.headline)
                Button(action: {
                    showDelete = true
                }) {
                    Text("Elimina")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(8)
                }
                .contentShape(Rectangle())
                .alert(isPresented: $showDelete) {
                    Alert(
                      title: Text("Elimina progetto"),
                      message: Text("Sei sicuro di voler eliminare \(project.name)?"),
                      primaryButton: .destructive(Text("Elimina")) {
                          if projectManager.backupProjects.contains(where: {
                              $0.id == project.id }) {
                              projectManager.deleteBackupProject(project: project)
                          } else {
                              projectManager.deleteProject(project: project)
                          }
                          presentationMode.wrappedValue.dismiss()
                      },
                      secondaryButton: .cancel()
                    )
                }
            }
        }
        .padding()
    }
}

// MARK: - ProjectEditToggleButton
struct ProjectEditToggleButton: View {
    @Binding var isEditing: Bool
    var body: some View {
        Button(action: { isEditing.toggle() }) {
            Text(isEditing ? "Fatto" : "Modifica")
                .font(.headline)
                .padding(8)
                .foregroundColor(.blue)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - ProjectRowView
struct ProjectRowView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool

    @State private var isHighlighted = false
    @State private var showSheet = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                guard projectManager.lockedLabelID == nil
                      || project.labelID == projectManager.lockedLabelID
                else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    isHighlighted = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isHighlighted = false
                    }
                    projectManager.currentProject = project
                }
            }) {
                HStack {
                    Text(project.name)
                        .font(.title3)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .disabled(
                projectManager.lockedLabelID != nil
                && project.labelID != projectManager.lockedLabelID
            )
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())

            Divider().frame(width: 1).background(Color.gray)

            Button(action: { showSheet = true }) {
                Text(editingProjects ? "Rinomina o Elimina" : "Etichetta")
                    .font(.footnote)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }
            .contentShape(Rectangle())
        }
        .background(
            projectManager.isProjectRunning(project)
            ? Color.yellow
            : (isHighlighted ? Color.gray.opacity(0.3) : Color.clear)
        )
        .sheet(isPresented: $showSheet) {
            if editingProjects {
                CombinedProjectEditSheet(
                  project: project,
                  projectManager: projectManager)
            } else {
                LabelAssignmentView(
                  project: project,
                  projectManager: projectManager)
            }
        }
        .onDrag {
            NSItemProvider(object: project.id.uuidString as NSString)
        }
    }
}

// MARK: - LabelHeaderView
struct LabelHeaderView: View {
    let label: ProjectLabel
    @ObservedObject var projectManager: ProjectManager
    var isBackup = false

    @State private var isTargeted = false

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
            Button(action: {
                if projectManager.lockedLabelID != label.id {
                    projectManager.lockedLabelID = label.id
                    if let first = projectManager.projects.first(
                       where: { $0.labelID == label.id }) {
                        projectManager.currentProject = first
                    }
                } else {
                    projectManager.lockedLabelID = nil
                    projectManager.currentProject = projectManager.projects.first
                }
                projectManager.cleanupEmptyLock()
            }) {
                Image(systemName:
                      projectManager.lockedLabelID == label.id
                      ? "lock.fill" : "lock.open")
                    .foregroundColor(.black)
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
        }
        .padding(.vertical, 8)
        .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .onDrop(of: [UTType.text.identifier], isTargeted: $isTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.text.identifier,
                                      options: nil) { data, _ in
                guard let data = data as? Data,
                      let str = String(data: data, encoding: .utf8),
                      let uuid = UUID(uuidString: str)
                else { return }
                DispatchQueue.main.async {
                    if isBackup {
                        if let i = projectManager.backupProjects.firstIndex(where: {
                            $0.id == uuid }) {
                            projectManager.backupProjects[i].labelID = label.id
                            projectManager.saveBackupOrder()
                        }
                    } else {
                        if let i = projectManager.projects.firstIndex(where: {
                            $0.id == uuid }) {
                            projectManager.projects[i].labelID = label.id
                            projectManager.saveProjects()
                            projectManager.cleanupEmptyLock()
                        }
                    }
                }
            }
            return true
        }
    }
}

// MARK: - LabelsManagerView
enum LabelActionType: Identifiable {
    case rename(label: ProjectLabel, initialText: String)
    case delete(label: ProjectLabel)
    case changeColor(label: ProjectLabel)
    var id: UUID {
        switch self {
        case .rename(let l, _):  return l.id
        case .delete(let l):     return l.id
        case .changeColor(let l):return l.id
        }
    }
}

struct LabelsManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newLabelTitle = ""
    @State private var newLabelColor: Color = .black
    @State private var activeAction: LabelActionType? = nil
    @State private var isEditingLabels = false

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels) { label in
                        HStack(spacing: 12) {
                            Button(action: {
                                activeAction = .changeColor(label: label)
                            }) {
                                Circle()
                                    .fill(Color(hex: label.color))
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contentShape(Rectangle())

                            Text(label.title)
                            Spacer()
                            Button("Rinomina") {
                                activeAction = .rename(
                                  label: label,
                                  initialText: label.title)
                            }
                            .foregroundColor(.blue)
                            .buttonStyle(BorderlessButtonStyle())
                            .contentShape(Rectangle())
                            Button("Elimina") {
                                activeAction = .delete(label: label)
                            }
                            .foregroundColor(.red)
                            .buttonStyle(BorderlessButtonStyle())
                            .contentShape(Rectangle())
                        }
                    }
                    .onMove { idx, off in
                        projectManager.labels.move(
                          fromOffsets: idx, toOffset: off)
                        projectManager.saveLabels()
                    }
                }
                .listStyle(PlainListStyle())

                HStack {
                    TextField("Nuova etichetta", text: $newLabelTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    ColorPicker("", selection: $newLabelColor,
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 50)
                    Button("Crea") {
                        guard !newLabelTitle.isEmpty else { return }
                        projectManager.addLabel(
                          title: newLabelTitle,
                          color: UIColor(newLabelColor).toHex)
                        newLabelTitle = ""
                        newLabelColor = .black
                    }
                    .foregroundColor(.green)
                    .padding(8)
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: 2))
                    .contentShape(Rectangle())
                }
                .padding()
            }
            .navigationTitle("Etichette")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .contentShape(Rectangle())
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditingLabels ? "Fatto" : "Ordina") {
                        isEditingLabels.toggle()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                    .contentShape(Rectangle())
                }
            }
            .environment(\.editMode,
                          .constant(isEditingLabels ? .active : .inactive))
            .sheet(item: $activeAction) { action in
                switch action {
                case .rename(let l, let txt):
                    RenameLabelSheetWrapper(
                      projectManager: projectManager,
                      label: l,
                      initialText: txt
                    ) { activeAction = nil }
                case .delete(let l):
                    DeleteLabelSheetWrapper(
                      projectManager: projectManager,
                      label: l
                    ) { activeAction = nil }
                case .changeColor(let l):
                    ChangeLabelColorDirectSheet(
                      projectManager: projectManager,
                      label: l
                    ) { activeAction = nil }
                }
            }
        }
    }
}

// MARK: - Rename / Delete / Color Sheets
struct RenameLabelSheetWrapper: View {
    @ObservedObject var projectManager: ProjectManager
    @State var label: ProjectLabel
    @State var newName: String
    var onDismiss: ()->Void

    init(projectManager: ProjectManager,
         label: ProjectLabel,
         initialText: String,
         onDismiss: @escaping ()->Void)
    {
        self.projectManager = projectManager
        _label   = State(initialValue: label)
        _newName = State(initialValue: initialText)
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Rinomina Etichetta").font(.title)
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
            .contentShape(Rectangle())
        }
        .padding()
    }
}

struct DeleteLabelSheetWrapper: View {
    @ObservedObject var projectManager: ProjectManager
    var label: ProjectLabel
    var onDismiss: ()->Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Elimina Etichetta").font(.title).bold()
            Text("Sei sicuro di voler eliminare l'etichetta \(label.title)?")
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
            .contentShape(Rectangle())
            Button(action: { onDismiss() }) {
                Text("Annulla")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray)
                    .cornerRadius(8)
            }
            .contentShape(Rectangle())
        }
        .padding()
    }
}

struct ChangeLabelColorDirectSheet: View {
    @ObservedObject var projectManager: ProjectManager
    @State var label: ProjectLabel
    @State var selectedColor: Color
    var onDismiss: ()->Void

    init(projectManager: ProjectManager,
         label: ProjectLabel,
         onDismiss: @escaping ()->Void)
    {
        self.projectManager = projectManager
        _label         = State(initialValue: label)
        _selectedColor = State(initialValue: Color(hex: label.color))
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .fill(selectedColor)
                .frame(width: 150, height: 150)
                .offset(y: -50)
            Text("Scegli un Colore").font(.title)
            ColorPicker("", selection: $selectedColor,
                        supportsOpacity: false)
                .labelsHidden()
                .padding()
            Button(action: {
                if let i = projectManager.labels.firstIndex(where: {
                    $0.id == label.id }) {
                    projectManager.labels[i].color =
                      UIColor(selectedColor).toHex
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
            .contentShape(Rectangle())
            Button(action: { onDismiss() }) {
                Text("Annulla")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(8)
            }
            .contentShape(Rectangle())
        }
        .padding()
    }
}

// MARK: - NoteView
struct NoteView: View {
    @ObservedObject var project: Project
    var projectManager: ProjectManager

    @State private var editMode = false
    @State private var editedRows: [NoteRow] = []

    private var projectNameColor: Color {
        if let lid = project.labelID,
           let hex = projectManager.labels.first(
             where: { $0.id == lid })?.color
        {
            return Color(hex: hex)
        }
        return .black
    }

    var body: some View {
        ZStack {
            // dynamic background
            if projectManager.isProjectRunning(project) {
                Color.yellow
            } else {
                Color.white.opacity(0.2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let lid = project.labelID,
                           let lab = projectManager.labels.first(
                             where: { $0.id == lid })
                        {
                            HStack(spacing: 8) {
                                Text(lab.title)
                                    .font(.headline)
                                    .bold()
                                Circle()
                                    .fill(Color(hex: lab.color))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                            }
                            .foregroundColor(.black)
                        }
                        Text(project.name)
                            .font(.title3)
                            .bold()
                            .underline(true, color: projectNameColor)
                            .foregroundColor(.black)
                        Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                            .font(.body)
                            .bold()
                    }
                    Spacer()
                    if editMode {
                        VStack {
                            Button(action: {
                                var rows = editedRows.filter {
                                    !($0.giorno.trimmingCharacters(
                                        in: .whitespaces).isEmpty &&
                                      $0.orari.trimmingCharacters(
                                        in: .whitespaces).isEmpty &&
                                      $0.note.trimmingCharacters(
                                        in: .whitespaces).isEmpty)
                                }
                                rows.sort {
                                    guard let d1 = project.dateFromGiorno($0.giorno),
                                          let d2 = project.dateFromGiorno($1.giorno)
                                    else { return $0.giorno < $1.giorno }
                                    return d1 < d2
                                }
                                project.noteRows = rows
                                projectManager.saveProjects()
                                editMode = false
                            }) {
                                Text("Salva").foregroundColor(.blue)
                            }
                            .contentShape(Rectangle())
                            Button(action: {
                                editMode = false
                            }) {
                                Text("Annulla").foregroundColor(.red)
                            }
                            .contentShape(Rectangle())
                        }
                        .font(.body)
                    } else {
                        Button(action: {
                            editedRows = project.noteRows
                            editMode = true
                        }) {
                            Text("Modifica")
                                .font(.body)
                                .foregroundColor(.blue)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .padding(.bottom, 5)

                if editMode {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach($editedRows) { $row in
                                HStack(spacing: 8) {
                                    TextField("Giorno", text: $row.giorno)
                                        .font(.system(size: 14))
                                        .frame(height: 60)
                                    Divider().frame(height: 60).background(Color.black)
                                    TextEditor(text: $row.orari)
                                        .font(.system(size: 14))
                                        .frame(height: 60)
                                    Divider().frame(height: 60).background(Color.black)
                                    Text(row.totalTimeString)
                                        .font(.system(size: 14))
                                        .frame(height: 60)
                                    Divider().frame(height: 60).background(Color.black)
                                    TextField("Note", text: $row.note)
                                        .font(.system(size: 14))
                                        .frame(height: 60)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(project.noteRows) { row in
                                HStack(spacing: 8) {
                                    Text(row.giorno)
                                        .font(.system(size: 14))
                                        .frame(minHeight: 60)
                                    Divider().frame(height: 60).background(Color.black)
                                    Text(row.orari)
                                        .font(.system(size: 14))
                                        .frame(minHeight: 60)
                                    Divider().frame(height: 60).background(Color.black)
                                    Text(row.totalTimeString)
                                        .font(.system(size: 14))
                                        .frame(minHeight: 60)
                                    Divider().frame(height: 60).background(Color.black)
                                    Text(row.note)
                                        .font(.system(size: 14))
                                        .frame(minHeight: 60)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(20)
        }
        .cornerRadius(25)
        .clipped()
    }
}

// MARK: - ComeFunzionaSheetView
struct ComeFunzionaSheetView: View {
    var onDismiss: ()->Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Funzionalità generali").font(.headline)
                    Text("""
                    • Tieni premuto il bottone per avviare/fermare il tempo.\
                    • I dati vengono salvati e archiviati mensilmente automaticamente.
                    """)
                }
                Group {
                    Text("Etichette").font(.headline)
                    Text("""
                    • Usa le etichette per raggruppare progetti.\
                    • Tieni premuto per ordinarle.
                    """)
                }
                Group {
                    Text("Progetti nascosti").font(.headline)
                    Text("""
                    • I backup mensili sono di sola lettura.
                    """)
                }
                Group {
                    Text("Buone pratiche e consigli").font(.headline)
                    Text("""
                    • Denomina i progetti in modo conciso.\
                    • Aggiungi ✅ nelle note per confermare il trasferimento ore.\
                    • Non includere mese/anno nel titolo: l’app archivia automaticamente.
                    """)
                }
            }
            .padding()
        }
        .background(Color.white)
        .cornerRadius(12)
        .padding()
        .overlay(
            Button(action: { onDismiss() }) {
                Text("Chiudi")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal),
            alignment: .bottom
        )
    }
}

// MARK: - ProjectManagerView
struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager

    @State private var newProjectName = ""
    @State private var showEtichette = false

    @State private var showImport = false
    @State private var importError: AlertError? = nil
    @State private var pendingImport: ProjectManager.ExportData? = nil
    @State private var showImportConfirm = false

    @State private var showHow = false
    @State private var showHowButton = false

    @State private var editMode: EditMode = .inactive
    @State private var editingProjects = false

    @State private var showExportOpts = false
    @State private var exportURL: URL? = nil
    @State private var showActivity = false

    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header:
                        Text("Progetti Correnti")
                            .font(.largeTitle).bold()
                            .padding(.top, 10)
                    ) {
                        let unl = projectManager.projects.filter { $0.labelID == nil }
                        if !unl.isEmpty {
                            ForEach(unl) { p in
                                ProjectRowView(
                                  project: p,
                                  projectManager: projectManager,
                                  editingProjects: editingProjects)
                            }
                            .onMove { idx, off in
                                projectManager.moveProjects(
                                  forLabel: nil,
                                  indices: idx,
                                  newOffset: off)
                            }
                        }
                        ForEach(projectManager.labels) { lab in
                            LabelHeaderView(
                              label: lab,
                              projectManager: projectManager)
                            let grp = projectManager.projects
                                       .filter { $0.labelID == lab.id }
                            if !grp.isEmpty {
                                ForEach(grp) { p in
                                    ProjectRowView(
                                      project: p,
                                      projectManager: projectManager,
                                      editingProjects: editingProjects)
                                }
                                .onMove { idx, off in
                                    projectManager.moveProjects(
                                      forLabel: lab.id,
                                      indices: idx,
                                      newOffset: off)
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
                                ProjectRowView(
                                  project: p,
                                  projectManager: projectManager,
                                  editingProjects: editingProjects)
                            }
                            .onMove { idx, off in
                                projectManager.moveBackupProjects(
                                  forLabel: nil,
                                  indices: idx,
                                  newOffset: off)
                            }
                        }
                        ForEach(projectManager.labels) { lab in
                            let grp = projectManager.backupProjects
                                       .filter { $0.labelID == lab.id }
                            if !grp.isEmpty {
                                LabelHeaderView(
                                  label: lab,
                                  projectManager: projectManager,
                                  isBackup: true)
                                ForEach(grp) { p in
                                    ProjectRowView(
                                      project: p,
                                      projectManager: projectManager,
                                      editingProjects: editingProjects)
                                }
                                .onMove { idx, off in
                                    projectManager.moveBackupProjects(
                                      forLabel: lab.id,
                                      indices: idx,
                                      newOffset: off)
                                }
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .environment(\.editMode, $editMode)

                HStack {
                    TextField("Nuovo progetto", text: $newProjectName)
                        .font(.title3)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        guard !newProjectName.isEmpty else { return }
                        projectManager.addProject(name: newProjectName)
                        newProjectName = ""
                    }) {
                        Text("Crea")
                            .font(.title3)
                            .foregroundColor(.green)
                            .padding(8)
                            .overlay(
                              RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.green, lineWidth: 2)
                            )
                    }
                    .contentShape(Rectangle())

                    Button(action: { showEtichette = true }) {
                        Text("Etichette")
                            .font(.title3)
                            .foregroundColor(.red)
                            .padding(8)
                            .overlay(
                              RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red, lineWidth: 2)
                            )
                    }
                    .contentShape(Rectangle())
                }
                .padding()

                HStack {
                    Button(action: { showExportOpts = true }) {
                        Text("Condividi Monte Ore")
                            .font(.title3)
                            .foregroundColor(.purple)
                            .padding()
                            .overlay(
                              RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.purple, lineWidth: 2)
                            )
                    }
                    .contentShape(Rectangle())

                    Spacer()

                    Button(action: { showImport = true }) {
                        Text("Importa File")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .padding()
                            .overlay(
                              RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange, lineWidth: 2)
                            )
                    }
                    .contentShape(Rectangle())
                }
                .padding(.horizontal)
            }
            .navigationBarTitle("", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ProjectEditToggleButton(isEditing: $editingProjects)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showHowButton {
                        Button(action: { showHow = true }) {
                            Text("Come funziona l'app")
                                .font(.custom("Permanent Marker", size: 20))
                                .foregroundColor(.black)
                                .padding(8)
                                .background(Color.yellow)
                                .cornerRadius(8)
                        }
                        .contentShape(Rectangle())
                    } else {
                        Button(action: { showHowButton = true }) {
                            Text("?")
                                .font(.system(size: 40))
                                .bold()
                                .foregroundColor(.yellow)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .sheet(isPresented: $showEtichette) {
                LabelsManagerView(projectManager: projectManager)
            }
            .confirmationDialog("Esporta Monte Ore",
                                isPresented: $showExportOpts,
                                titleVisibility: .visible) {
                Button("Backup (JSON)") {
                    exportURL = projectManager.getExportURL()
                    showActivity = true
                }
                Button("Esporta CSV monte ore") {
                    exportURL = projectManager.getCSVExportURL()
                    showActivity = true
                }
                Button("Annulla", role: .cancel) {}
            }
            .sheet(isPresented: $showActivity) {
                if let url = exportURL {
                    ActivityView(activityItems: [url])
                } else {
                    Text("Errore nell'esportazione")
                }
            }
            .fileImporter(isPresented: $showImport,
                          allowedContentTypes: [UTType.json]) { res in
                switch res {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else {
                        importError = AlertError(
                          message: "Non è possibile accedere al file.")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        let imp  = try JSONDecoder()
                                      .decode(ProjectManager.ExportData.self,
                                              from: data)
                        pendingImport = imp
                        showImportConfirm = true
                    } catch {
                        importError = AlertError(
                          message: "Errore nell'import: \(error)")
                    }
                case .failure(let err):
                    importError = AlertError(
                      message: "Errore: \(err.localizedDescription)")
                }
            }
            .alert(item: $importError) { e in
                Alert(title: Text("Errore"),
                      message: Text(e.message),
                      dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showImportConfirm) {
                if let pending = pendingImport {
                    ImportConfirmationView(
                        message: "Attenzione: sovrascrivere tutto?",
                        importAction: {
                            projectManager.projects       = pending.projects
                            projectManager.backupProjects = pending.backupProjects.map {
                              var p = $0; p.id = UUID(); return p
                            }
                            projectManager.saveBackupOrder()
                            projectManager.labels         = pending.labels
                            if let l = pending.lockedLabelID,
                               let u = UUID(uuidString: l) {
                                projectManager.lockedLabelID = u
                            } else {
                                projectManager.lockedLabelID = nil
                            }
                            projectManager.currentProject = projectManager.projects.first
                            projectManager.saveProjects()
                            projectManager.saveLabels()
                            projectManager.saveBackupProjects()
                            pendingImport = nil
                            showImportConfirm = false
                        },
                        cancelAction: {
                            pendingImport = nil
                            showImportConfirm = false
                        }
                    )
                } else {
                    Text("Errore: nessun dato da importare.")
                }
            }
            .sheet(isPresented: $showHow,
                   onDismiss: { showHowButton = false }) {
                ComeFunzionaSheetView { showHow = false }
            }
            .onAppear {
                NotificationCenter.default.addObserver(
                  forName: Notification.Name("CycleProjectNotification"),
                  object: nil, queue: .main) { _ in
                    cycleProject()
                }
            }
        }
    }

    private func cycleProject() {
        if let cur = projectManager.currentProject,
           projectManager.backupProjects.map(\.id).contains(cur.id)
        {
            let avail = projectManager.backupProjects
            guard let idx = avail.firstIndex(where: { $0.id == cur.id }),
                  avail.count > 1 else { return }
            projectManager.currentProject = avail[(idx + 1) % avail.count]
            return
        }
        let avail: [Project]
        if let lid = projectManager.lockedLabelID {
          avail = projectManager.projects.filter { $0.labelID == lid }
        } else {
          var list: [Project] = []
          list += projectManager.projects.filter { $0.labelID == nil }
          for lab in projectManager.labels {
            list += projectManager.projects.filter { $0.labelID == lab.id }
          }
          avail = list
        }
        guard let cur = projectManager.currentProject,
              let idx = avail.firstIndex(where: { $0.id == cur.id }),
              avail.count > 1 else { return }
        projectManager.currentProject = avail[(idx + 1) % avail.count]
    }

    private func previousProject() {
        if let cur = projectManager.currentProject,
           projectManager.backupProjects.map(\.id).contains(cur.id)
        {
            let avail = projectManager.backupProjects
            guard let idx = avail.firstIndex(where: { $0.id == cur.id }),
                  avail.count > 1 else { return }
            projectManager.currentProject = avail[(idx - 1 + avail.count) % avail.count]
            return
        }
        let avail: [Project]
        if let lid = projectManager.lockedLabelID {
          avail = projectManager.projects.filter { $0.labelID == lid }
        } else {
          var list: [Project] = []
          list += projectManager.projects.filter { $0.labelID == nil }
          for lab in projectManager.labels {
            list += projectManager.projects.filter { $0.labelID == lab.id }
          }
          avail = list
        }
        guard let cur = projectManager.currentProject,
              let idx = avail.firstIndex(where: { $0.id == cur.id }),
              avail.count > 1 else { return }
        projectManager.currentProject = avail[(idx - 1 + avail.count) % avail.count]
    }
}

// MARK: - ImportConfirmationView
struct ImportConfirmationView: View {
    let message: String
    let importAction: ()->Void
    let cancelAction: ()->Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Importa File").font(.title).bold()
            Text(message).multilineTextAlignment(.center).padding()
            HStack {
                Button(action: cancelAction) {
                    Text("Annulla")
                        .foregroundColor(.red)
                        .padding()
                        .overlay(
                          RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red, lineWidth: 2))
                }
                .contentShape(Rectangle())

                Button(action: importAction) {
                    Text("Importa")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.yellow)
                        .cornerRadius(8)
                }
                .contentShape(Rectangle())
            }
        }
        .padding()
    }
}

// MARK: - Supporting Views
struct NoNotesPromptView: View {
    var onOk: ()->Void
    var onNonCHoSbatti: ()->Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Nessun progetto attivo")
                .font(.title).bold()
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
                .contentShape(Rectangle())

                Button(action: onNonCHoSbatti) {
                    Text("Non CHo Sbatti")
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .contentShape(Rectangle())
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
    var onDismiss: ()->Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Frate, nemmeno io...")
                .font(.custom("Permanent Marker", size: 28))
                .bold()
                .multilineTextAlignment(.center)
            Button(action: onDismiss) {
                Text("Mh")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
            }
            .contentShape(Rectangle())
        }
        .padding(30)
    }
}

// MARK: - App Entry
@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()

    @State private var showManager = false
    @State private var showNoSbatti = false
    @State private var showMedal   = false
    @AppStorage("medalAwarded") private var medalAwarded = false

    var body: some View {
        GeometryReader { geo in
            let isLand = geo.size.width > geo.size.height
            let noProj = projectManager.currentProject == nil
            let isBackup = projectManager.currentProject.flatMap {
                proj in projectManager.backupProjects.first(
                          where: { $0.id == proj.id })
            } != nil

            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)

                VStack(spacing: 20) {
                    if noProj {
                        NoNotesPromptView(
                          onOk:    { showManager = true },
                          onNonCHoSbatti: { showNoSbatti = true })
                    } else {
                        if let proj = projectManager.currentProject {
                            NoteView(
                              project: proj,
                              projectManager: projectManager)
                            .frame(
                              width: isLand ? geo.size.width
                                            : geo.size.width - 40,
                              height: isLand ? geo.size.height * 0.4
                                            : geo.size.height * 0.6)
                        }
                    }

                    // Pigia il tempo or hidden overlay
                    ZStack {
                        Button(action: { mainButtonTapped() }) {
                            Text("Pigia il tempo")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(
                                  width: isLand ? 100 : 140,
                                  height: isLand ? 100 : 140)
                                .background(Circle().fill(Color.black))
                        }
                        .disabled(isBackup || projectManager.currentProject == nil)

                        if isBackup {
                            Circle()
                                .fill(Color(hex: "#54c0ff"))
                                .frame(
                                  width: isLand ? 100 : 140,
                                  height: isLand ? 100 : 140)
                        }
                    }

                    // Gestione / Cambia split
                    HStack {
                        Button(action: { showManager = true }) {
                            Text("Gestione\nProgetti")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.black)
                                .frame(
                                  width: isLand ? 90 : 140,
                                  height: isLand ? 100 : 140)
                                .background(Circle().fill(Color.white))
                                .overlay(
                                  Circle().stroke(Color.black, lineWidth: 2))
                        }
                        .contentShape(Rectangle())

                        Spacer()

                        ZStack {
                            Circle()
                                .fill(Color.yellow)
                                .frame(
                                  width: isLand ? 90 : 140,
                                  height: isLand ? 90 : 140)
                                .overlay(
                                  Rectangle()
                                    .frame(
                                      width: (isLand ? 90 : 140),
                                      height: 1),
                                  alignment: .center
                                )

                            VStack(spacing: 0) {
                              Button(action: previousProject) {
                                Color.clear
                              }
                              .frame(height: (isLand ? 45 : 70))

                              Button(action: cycleProject) {
                                Color.clear
                              }
                              .frame(height: (isLand ? 45 : 70))
                            }

                            VStack {
                              Image(systemName: "chevron.up")
                                .font(.title2)
                                .padding(.top, 16)
                              Spacer()
                              Image(systemName: "chevron.down")
                                .font(.title2)
                                .padding(.bottom, 16)
                            }
                        }
                        .disabled(isBackup || projectManager.currentProject == nil)
                    }
                    .padding(.horizontal, isLand ? 10 : 30)
                    .padding(.bottom, isLand ? 0 : 30)
                }

                if showMedal {
                    PopupView(message: "Congratulazioni! Hai guadagnato la medaglia \"Sbattimenti zero eh\"")
                        .transition(.scale)
                }
            }
            .sheet(isPresented: $showManager) {
                ProjectManagerView(projectManager: projectManager)
            }
            .sheet(isPresented: $showNoSbatti) {
                NonCHoSbattiSheetView {
                    if !medalAwarded {
                        medalAwarded = true
                        showMedal = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            withAnimation { showMedal = false }
                        }
                    }
                    showNoSbatti = false
                }
            }
        }
    }

    private func cycleProject() {
        if let cur = projectManager.currentProject,
           projectManager.backupProjects.map(\.id).contains(cur.id)
        {
            let avail = projectManager.backupProjects
            guard let idx = avail.firstIndex(where: { $0.id == cur.id }),
                  avail.count > 1 else { return }
            projectManager.currentProject = avail[(idx + 1) % avail.count]
            return
        }
        let avail: [Project]
        if let lid = projectManager.lockedLabelID {
          avail = projectManager.projects.filter { $0.labelID == lid }
        } else {
          var list: [Project] = []
          list += projectManager.projects.filter { $0.labelID == nil }
          for lab in projectManager.labels {
            list += projectManager.projects.filter { $0.labelID == lab.id }
          }
          avail = list
        }
        guard let cur = projectManager.currentProject,
              let idx = avail.firstIndex(where: { $0.id == cur.id }),
              avail.count > 1 else { return }
        projectManager.currentProject = avail[(idx + 1) % avail.count]
    }

    private func previousProject() {
        if let cur = projectManager.currentProject,
           projectManager.backupProjects.map(\.id).contains(cur.id)
        {
            let avail = projectManager.backupProjects
            guard let idx = avail.firstIndex(where: { $0.id == cur.id }),
                  avail.count > 1 else { return }
            projectManager.currentProject = avail[(idx - 1 + avail.count) % avail.count]
            return
        }
        let avail: [Project]
        if let lid = projectManager.lockedLabelID {
          avail = projectManager.projects.filter { $0.labelID == lid }
        } else {
          var list: [Project] = []
          list += projectManager.projects.filter { $0.labelID == nil }
          for lab in projectManager.labels {
            list += projectManager.projects.filter { $0.labelID == lab.id }
          }
          avail = list
        }
        guard let cur = projectManager.currentProject,
              let idx = avail.firstIndex(where: { $0.id == cur.id }),
              avail.count > 1 else { return }
        projectManager.currentProject = avail[(idx - 1 + avail.count) % avail.count]
    }

    private func mainButtonTapped() {
        guard let proj = projectManager.currentProject else {
            playSound(success: false)
            return
        }
        if projectManager.backupProjects.contains(where: { $0.id == proj.id }) {
            return
        }
        let now = Date()
        let df = DateFormatter(); df.locale = Locale(identifier: "it_IT")
        df.dateFormat = "EEEE dd/MM/yy"
        let giornoStr = df.string(from: now).capitalized
        let tf = DateFormatter(); tf.locale = Locale(identifier: "it_IT")
        tf.dateFormat = "HH:mm"
        let timeStr = tf.string(from: now)
        projectManager.backupCurrentProjectIfNeeded(
          proj, currentDate: now, currentGiorno: giornoStr)
        if proj.noteRows.isEmpty
           || proj.noteRows.last?.giorno != giornoStr
        {
            proj.noteRows.append(
              NoteRow(giorno: giornoStr, orari: timeStr + "-", note: ""))
        } else {
            var last = proj.noteRows.removeLast()
            if last.orari.hasSuffix("-") {
                last.orari += timeStr
            } else {
                last.orari += " " + timeStr + "-"
            }
            proj.noteRows.append(last)
        }
        projectManager.saveProjects()
        playSound(success: true)
    }

    private func playSound(success: Bool) {
        // Implement AVFoundation as needed
    }
}
