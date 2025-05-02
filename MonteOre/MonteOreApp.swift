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
        case 3:
            (a, r, g, b) = (255,
                             (int >> 8) * 17,
                             (int >> 4 & 0xF) * 17,
                             (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255,
                             int >> 16,
                             int >> 8 & 0xFF,
                             int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24,
                             int >> 16 & 0xFF,
                             int >> 8 & 0xFF,
                             int & 0xFF)
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
        var r: CGFloat = 0, g: CGFloat = 0,
            b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255),
                      Int(g * 255),
                      Int(b * 255))
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

    enum CodingKeys: String, CodingKey {
        case id, giorno, orari, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id     = try c.decode(UUID.self, forKey: .id)
        giorno = try c.decode(String.self, forKey: .giorno)
        orari  = try c.decode(String.self, forKey: .orari)
        note   = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
    init(giorno: String, orari: String, note: String = "") {
        self.giorno = giorno
        self.orari  = orari
        self.note   = note
    }

    var totalMinutes: Int {
        orari
          .split(separator: " ")
          .reduce(0) { sum, seg in
            let parts = seg.split(separator: "-")
            guard parts.count == 2,
                  let start = minutesFromString(String(parts[0])),
                  let end   = minutesFromString(String(parts[1]))
            else { return sum }
            return sum + max(0, end - start)
        }
    }
    var totalTimeString: String {
        let h = totalMinutes / 60, m = totalMinutes % 60
        return "\(h)h \(m)m"
    }
    private func minutesFromString(_ t: String) -> Int? {
        let p = t.split(separator: ":")
        guard p.count == 2,
              let h = Int(p[0]), let m = Int(p[1])
        else { return nil }
        return h * 60 + m
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

    enum CodingKeys: CodingKey {
        case id, name, noteRows, labelID
    }

    init(name: String) {
        self.name     = name
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
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(noteRows, forKey: .noteRows)
        try c.encode(labelID, forKey: .labelID)
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
                UserDefaults.standard.set(cp.id.uuidString,
                                          forKey: "lastProjectId")
            }
        }
    }

    @Published var lockedLabelID: UUID? {
        didSet {
            if let l = lockedLabelID {
                UserDefaults.standard.set(l.uuidString,
                                          forKey: "lockedLabelID")
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
        if let last = UserDefaults.standard.string(forKey: "lastProjectId"),
           let p = projects.first(where: { $0.id.uuidString == last }) {
            currentProject = p
        } else {
            currentProject = projects.first
        }
        if projects.isEmpty {
            currentProject = nil
            saveProjects()
        }
    }

    // MARK: CRUD Projects
    func addProject(name: String) {
        let p = Project(name: name)
        projects.append(p)
        currentProject = p
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(
          name: .init("CycleProjectNotification"), object: nil)
    }
    func renameProject(project: Project, newName: String) {
        project.name = newName
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(
          name: .init("CycleProjectNotification"), object: nil)
    }
    func deleteProject(project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: idx)
            if currentProject?.id == project.id {
                currentProject = projects.first
            }
            saveProjects()
            objectWillChange.send()
            NotificationCenter.default.post(
              name: .init("CycleProjectNotification"), object: nil)
        }
    }

    // MARK: Backups
    func deleteBackupProject(project: Project) {
        let url = getURLForBackup(project: project)
        try? FileManager.default.removeItem(at: url)
        if let idx = backupProjects.firstIndex(where: { $0.id == project.id }) {
            backupProjects.remove(at: idx)
        }
    }
    func isProjectRunning(_ project: Project) -> Bool {
        project.noteRows.last?.orari.hasSuffix("-") ?? false
    }

    // File URLs
    private func getProjectsFileURL() -> URL {
        let docs = FileManager.default
                     .urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(projectsFileName)
    }
    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: getProjectsFileURL())
        } catch {
            print("Error saving projects:", error)
        }
    }
    func loadProjects() {
        let url = getProjectsFileURL()
        if let data = try? Data(contentsOf: url),
           let arr  = try? JSONDecoder().decode([Project].self, from: data) {
            projects = arr
        }
    }

    private func getURLForBackup(project: Project) -> URL {
        let docs = FileManager.default
                     .urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("\(project.name).json")
    }
    func saveBackupProjects() {
        for proj in backupProjects {
            let url = getURLForBackup(project: proj)
            do {
                let data = try JSONEncoder().encode(proj)
                try data.write(to: url)
            } catch {
                print("Errore saving backup project:", error)
            }
        }
    }
    func loadBackupProjects() {
        backupProjects = []
        let docs = FileManager.default
                     .urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default
                            .contentsOfDirectory(at: docs,
                                                 includingPropertiesForKeys: nil)
        {
            for file in files {
                if file.lastPathComponent != projectsFileName,
                   file.pathExtension == "json",
                   let data = try? Data(contentsOf: file),
                   let b = try? JSONDecoder().decode(Project.self, from: data)
                {
                    backupProjects.append(b)
                }
            }
        }
    }

    // Monthly rollover
    func backupCurrentProjectIfNeeded(_ project: Project,
                                      currentDate: Date,
                                      currentGiorno: String)
    {
        guard let last = project.noteRows.last,
              last.giorno != currentGiorno,
              let lastDate = project.dateFromGiorno(last.giorno)
        else { return }

        let cal = Calendar.current
        if cal.component(.month, from: lastDate) !=
           cal.component(.month, from: currentDate)
        {
            let fmt = DateFormatter()
            fmt.locale     = Locale(identifier: "it_IT")
            fmt.dateFormat = "LLLL"
            let monthName   = fmt.string(from: lastDate).capitalized
            let yearSuffix  = String(cal.component(.year, from: lastDate) % 100)
            let backupName  = "\(project.name) \(monthName) \(yearSuffix)"
            let backupProj  = Project(name: backupName)
            backupProj.noteRows = project.noteRows

            let url = getURLForBackup(project: backupProj)
            do {
                let data = try JSONEncoder().encode(backupProj)
                try data.write(to: url)
            } catch {
                print("Errore backup:", error)
            }
            loadBackupProjects()
            project.noteRows.removeAll()
            saveProjects()
        }
    }

    // MARK: Labels
    func addLabel(title: String, color: String) {
        let l = ProjectLabel(title: title, color: color)
        labels.append(l)
        saveLabels()
        objectWillChange.send()
        NotificationCenter.default.post(
          name: .init("CycleProjectNotification"), object: nil)
    }
    func renameLabel(label: ProjectLabel, newTitle: String) {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            labels[idx].title = newTitle
            saveLabels()
            objectWillChange.send()
            NotificationCenter.default.post(
              name: .init("CycleProjectNotification"), object: nil)
        }
    }
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll(where: { $0.id == label.id })
        for p in projects    where p.labelID == label.id { p.labelID = nil }
        for p in backupProjects where p.labelID == label.id { p.labelID = nil }
        saveLabels()
        saveProjects()
        saveBackupProjects()
        objectWillChange.send()
        if lockedLabelID == label.id {
            lockedLabelID = nil
        }
        NotificationCenter.default.post(
          name: .init("CycleProjectNotification"), object: nil)
    }
    func saveLabels() {
        let docs = FileManager.default
                     .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("labels.json")
        do {
            let data = try JSONEncoder().encode(labels)
            try data.write(to: url)
        } catch {
            print("Errore saving labels:", error)
        }
    }
    func loadLabels() {
        let docs = FileManager.default
                     .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("labels.json")
        if let data = try? Data(contentsOf: url),
           let arr  = try? JSONDecoder().decode([ProjectLabel].self, from: data)
        {
            labels = arr
        }
    }

    // MARK: Reordering
    func moveProjects(forLabel labelID: UUID?,
                      indices: IndexSet,
                      newOffset: Int)
    {
        var group = projects.filter { $0.labelID == labelID }
        group.move(fromOffsets: indices, toOffset: newOffset)
        projects.removeAll { $0.labelID == labelID }
        projects.append(contentsOf: group)
    }
    func moveBackupProjects(forLabel labelID: UUID?,
                            indices: IndexSet,
                            newOffset: Int)
    {
        var group = backupProjects.filter { $0.labelID == labelID }
        group.move(fromOffsets: indices, toOffset: newOffset)
        backupProjects.removeAll { $0.labelID == labelID }
        backupProjects.append(contentsOf: group)
    }

    // MARK: Exports
    func getExportURL() -> URL? {
        struct ExportData: Codable {
            let projects: [Project]
            let backupProjects: [Project]
            let labels: [ProjectLabel]
            let lockedLabelID: String?
        }
        let d = ExportData(
          projects: projects,
          backupProjects: backupProjects,
          labels: labels,
          lockedLabelID: lockedLabelID?.uuidString
        )
        do {
            let data = try JSONEncoder().encode(d)
            let url = FileManager.default.temporaryDirectory
                       .appendingPathComponent("MonteOreExport.json")
            try data.write(to: url)
            return url
        } catch {
            print("Errore export JSON:", error)
            return nil
        }
    }
    func getCSVExportURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
                  .appendingPathComponent("MonteOreExport.txt")
        var text = ""
        for p in projects {
            text += "\"\(p.name)\",\"\(p.totalProjectTimeString)\"\n"
            for row in p.noteRows {
                text += "\(row.giorno),\"\(row.orari)\",\"\(row.totalTimeString)\",\"\(row.note)\"\n"
            }
            text += "\n"
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("Errore CSV export:", error)
            return nil
        }
    }
}

// MARK: - ActivityView (for sharing)
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
          activityItems: activityItems,
          applicationActivities: applicationActivities
        )
    }
    func updateUIViewController(
      _ uiViewController: UIActivityViewController,
      context: Context
    ) {}
}

// MARK: - Label Assignment
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
                            projectManager.objectWillChange.send()
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
                    Button("Annulla") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Rename/Delete Sheet
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
                Button("Conferma") {
                    projectManager.renameProject(project: project, newName: newName)
                    presentationMode.wrappedValue.dismiss()
                }
                .font(.title2)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .cornerRadius(8)
            }

            Divider()

            VStack {
                Text("Elimina")
                    .font(.headline)
                Button("Elimina") {
                    showDeleteConfirmation = true
                }
                .font(.title2)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red)
                .cornerRadius(8)
                .alert(isPresented: $showDeleteConfirmation) {
                    Alert(
                        title: Text("Elimina progetto"),
                        message: Text("Sei sicuro di voler eliminare il progetto \(project.name)?"),
                        primaryButton: .destructive(Text("Elimina")) {
                            projectManager.deleteProject(project: project)
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

// MARK: - Edit Toggle
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

// MARK: - Project Row
struct ProjectRowView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    var editingProjects: Bool

    @State private var isHighlighted: Bool = false
    @State private var showSecondarySheet = false

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
            .buttonStyle(PlainButtonStyle())
            .disabled(
              projectManager.lockedLabelID != nil
              && project.labelID != projectManager.lockedLabelID
            )

            Divider()
                .frame(width: 1)
                .background(Color.gray)

            Button(action: {
                showSecondarySheet = true
            }) {
                Text(editingProjects ? "Rinomina o Elimina" : "Etichetta")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }
        }
        .background(
            projectManager.isProjectRunning(project)
            ? Color.yellow
            : (isHighlighted
               ? Color.gray.opacity(0.3)
               : Color.clear)
        )
        .sheet(isPresented: $showSecondarySheet) {
            if editingProjects {
                CombinedProjectEditSheet(
                  project: project,
                  projectManager: projectManager
                )
            } else {
                LabelAssignmentView(
                  project: project,
                  projectManager: projectManager
                )
            }
        }
        .onDrag {
            NSItemProvider(object: project.id.uuidString as NSString)
        }
    }
}

// MARK: - Label Header
struct LabelHeaderView: View {
    let label: ProjectLabel
    @ObservedObject var projectManager: ProjectManager
    var isBackup: Bool = false

    @State private var showLockInfo = false
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
            if !isBackup,
               projectManager.projects.contains(where: { $0.labelID == label.id })
            {
                Button(action: {
                    if projectManager.lockedLabelID != label.id {
                        projectManager.lockedLabelID = label.id
                        showLockInfo = true
                    } else {
                        projectManager.lockedLabelID = nil
                    }
                }) {
                    Image(
                      systemName:
                        projectManager.lockedLabelID == label.id
                        ? "lock.fill" : "lock.open"
                    )
                    .foregroundColor(.black)
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showLockInfo,
                         arrowEdge: .bottom) {
                    VStack(spacing: 20) {
                        Text(
                          "Il pulsante è agganciato ai progetti dell'etichetta \(label.title)"
                        )
                        .font(.title)  // bigger
                        .bold()
                        .multilineTextAlignment(.center)
                        .padding()
                        Button("Chiudi") {
                            showLockInfo = false
                        }
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
        .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .onDrop(of: [UTType.text.identifier],
                isTargeted: $isTargeted) { providers in
            providers.first?.loadItem(
              forTypeIdentifier: UTType.text.identifier,
              options: nil
            ) { data, _ in
                guard let data = data as? Data,
                      let idStr = String(data: data, encoding: .utf8),
                      let uuid = UUID(uuidString: idStr)
                else { return }
                DispatchQueue.main.async {
                    if isBackup {
                        if let i = projectManager.backupProjects
                                     .firstIndex(where: { $0.id == uuid })
                        {
                            projectManager.backupProjects[i].labelID = label.id
                            projectManager.saveBackupProjects()
                            projectManager.objectWillChange.send()
                            NotificationCenter.default.post(
                              name: .init("CycleProjectNotification"),
                              object: nil
                            )
                        }
                    } else {
                        if let i = projectManager.projects
                                     .firstIndex(where: { $0.id == uuid })
                        {
                            projectManager.projects[i].labelID = label.id
                            projectManager.saveProjects()
                            projectManager.objectWillChange.send()
                            NotificationCenter.default.post(
                              name: .init("CycleProjectNotification"),
                              object: nil
                            )
                        }
                    }
                }
            }
            return true
        }
        .onAppear { unlockIfEmpty() }
        .onReceive(projectManager.$projects) { _ in
            unlockIfEmpty()
        }
    }

    private func unlockIfEmpty() {
        if let locked = projectManager.lockedLabelID,
           !projectManager.projects.contains(where: { $0.labelID == locked })
        {
            projectManager.lockedLabelID = nil
        }
    }
}

// MARK: - Labels Manager
struct LabelsManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode

    @State private var newLabelTitle = ""
    @State private var newLabelColor: Color = .black
    @State private var activeLabelAction: LabelActionType? = nil
    @State private var isEditingLabels = false

    enum LabelActionType: Identifiable {
        case rename(label: ProjectLabel, initial: String)
        case delete(label: ProjectLabel)
        case changeColor(label: ProjectLabel)
        var id: UUID {
            switch self {
            case .rename(let l, _): return l.id
            case .delete(let l):    return l.id
            case .changeColor(let l):return l.id
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels) { label in
                        HStack(spacing: 12) {
                            Button {
                                activeLabelAction = .changeColor(label: label)
                            } label: {
                                Circle()
                                    .fill(Color(hex: label.color))
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Text(label.title)
                            Spacer()
                            Button("Rinomina") {
                                activeLabelAction = .rename(
                                  label: label,
                                  initial: label.title
                                )
                            }
                            .foregroundColor(.blue)
                            .buttonStyle(BorderlessButtonStyle())

                            Button("Elimina") {
                                activeLabelAction = .delete(label: label)
                            }
                            .foregroundColor(.red)
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .onMove { indices, newOffset in
                        projectManager.labels.move(
                          fromOffsets: indices, toOffset: newOffset)
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
                          color: UIColor(newLabelColor).toHex
                        )
                        newLabelTitle = ""
                        newLabelColor = .black
                    }
                    .foregroundColor(.green)
                    .padding(8)
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: 2)
                    )
                }
                .padding()
            }
            .navigationTitle("Etichette")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditingLabels ? "Fatto" : "Ordina") {
                        isEditingLabels.toggle()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                }
            }
            .environment(\.editMode,
                          .constant(isEditingLabels ? .active : .inactive))
            .sheet(item: $activeLabelAction) { action in
                switch action {
                case .rename(let label, let initial):
                    RenameLabelSheetWrapper(
                      projectManager: projectManager,
                      label: label,
                      initialText: initial
                    ) { activeLabelAction = nil }
                case .delete(let label):
                    DeleteLabelSheetWrapper(
                      projectManager: projectManager,
                      label: label
                    ) { activeLabelAction = nil }
                case .changeColor(let label):
                    ChangeLabelColorDirectSheet(
                      projectManager: projectManager,
                      label: label
                    ) { activeLabelAction = nil }
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

    init(projectManager: ProjectManager,
         label: ProjectLabel,
         initialText: String,
         onDismiss: @escaping () -> Void)
    {
        self.projectManager = projectManager
        _label   = State(initialValue: label)
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
            Button("Conferma") {
                projectManager.renameLabel(label: label, newTitle: newName)
                onDismiss()
            }
            .font(.title2)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .cornerRadius(8)
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
                .font(.title).bold()
            Text("Sei sicuro di voler eliminare l'etichetta \(label.title)?")
                .multilineTextAlignment(.center)
                .padding()
            Button {
                projectManager.deleteLabel(label: label)
                onDismiss()
            } label: {
                Text("Elimina")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(8)
            }
            Button {
                onDismiss()
            } label: {
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

// MARK: - Color‐picker Sheet
struct ChangeLabelColorDirectSheet: View {
    @ObservedObject var projectManager: ProjectManager
    @State var label: ProjectLabel
    @State var selectedColor: Color
    var onDismiss: () -> Void

    init(projectManager: ProjectManager,
         label: ProjectLabel,
         onDismiss: @escaping () -> Void)
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
                .offset(y: -50)  // preview raised 1/3
            Text("Scegli un Colore")
                .font(.title)
            ColorPicker("", selection: $selectedColor,
                        supportsOpacity: false)
                .labelsHidden()
                .padding()
            Button("Conferma") {
                if let idx = projectManager.labels
                             .firstIndex(where: { $0.id == label.id })
                {
                    projectManager.labels[idx].color =
                      UIColor(selectedColor).toHex
                    projectManager.saveLabels()
                }
                onDismiss()
            }
            .font(.title2)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .cornerRadius(8)

            Button("Annulla") {
                onDismiss()
            }
            .font(.title2)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.red)
            .cornerRadius(8)
        }
        .padding()
    }
}

// MARK: - Note View
struct NoteView: View {
    @ObservedObject var project: Project
    var projectManager: ProjectManager

    @State private var editMode = false
    @State private var editedRows: [NoteRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // — Header (locked)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    // 8) show label above
                    if let lid = project.labelID,
                       let lab = projectManager.labels
                                    .first(where: { $0.id == lid })
                    {
                        Text(lab.title)
                            .font(.headline)
                            .bold()
                            .foregroundColor(Color(hex: lab.color))
                    }
                    // 2) underlined, colored by label
                    Text(project.name)
                        .font(.title3)
                        .bold()
                        .underline()
                        .foregroundColor(
                            project.labelID.flatMap { lid in
                                projectManager.labels
                                  .first(where: { $0.id == lid })?.color
                            }.map(Color.init(hex:)) ?? .black
                        )
                    Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                        .font(.title3)
                        .bold()
                }
                Spacer()
                if editMode {
                    VStack {
                        Button("Salva") {
                            // 12) remove empty rows & reorder
                            var rows = editedRows.filter {
                                !(
                                  $0.giorno.trimmingCharacters(
                                    in: .whitespacesAndNewlines).isEmpty
                                  && $0.orari.trimmingCharacters(
                                    in: .whitespacesAndNewlines).isEmpty
                                  && $0.note.trimmingCharacters(
                                    in: .whitespacesAndNewlines).isEmpty
                                )
                            }
                            rows.sort {
                                if let d1 = project.dateFromGiorno($0.giorno),
                                   let d2 = project.dateFromGiorno($1.giorno)
                                {
                                    return d1 < d2
                                }
                                return $0.giorno < $1.giorno
                            }
                            project.noteRows = rows
                            editMode = false
                            projectManager.saveProjects()
                        }
                        .foregroundColor(.blue)
                        Button("Annulla") {
                            editMode = false
                        }
                        .foregroundColor(.red)
                    }
                    .font(.title3)
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

            // — Rows
            if editMode {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($editedRows) { $row in
                            HStack(spacing: 8) {
                                TextField("Giorno", text: $row.giorno)
                                    .font(.system(size: 15))
                                    .frame(height: 60)
                                Divider()
                                    .frame(height: 60)
                                    .background(Color.black)
                                TextEditor(text: $row.orari)
                                    .font(.system(size: 15))
                                    .frame(height: 60)
                                Divider()
                                    .frame(height: 60)
                                    .background(Color.black)
                                Text(row.totalTimeString)
                                    .font(.system(size: 15))
                                    .frame(height: 60)
                                Divider()
                                    .frame(height: 60)
                                    .background(Color.black)
                                TextField("Note", text: $row.note)
                                    .font(.system(size: 15))
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
                                    .font(.system(size: 15))
                                    .frame(minHeight: 60)
                                Divider()
                                    .frame(height: 60)
                                    .background(Color.black)
                                Text(row.orari)
                                    .font(.system(size: 15))
                                    .frame(minHeight: 60)
                                Divider()
                                    .frame(height: 60)
                                    .background(Color.black)
                                Text(row.totalTimeString)
                                    .font(.system(size: 15))
                                    .frame(minHeight: 60)
                                Divider()
                                    .frame(height: 60)
                                    .background(Color.black)
                                Text(row.note)
                                    .font(.system(size: 15))
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
}

// MARK: - How It Works
struct ComeFunzionaSheetView: View {
    var onDismiss: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Funzionalità generali")
                    .font(.headline)
                Text("""
                • Tieni premuto il bottone per avviare/fermare il tempo.\
                • I dati vengono salvati e archiviati mensilmente automaticamente.
                """)

                Text("Etichette")
                    .font(.headline)
                Text("""
                • Usa le etichette per raggruppare progetti simili (e.g. “Lavoro”).\
                • Premi e tieni premuto per riordinarle.\
                • Assegna un colore distintivo.
                """)

                Text("Progetti nascosti")
                    .font(.headline)
                Text("""
                • I backup mensili sono di sola lettura.\
                • Non è possibile temporizzare lì dentro.
                """)

                Text("Buone pratiche e consigli")
                    .font(.headline)
                Text("""
                • Denomina i progetti in modo conciso (e.g. “Excel”).\
                • Aggiungi ✅ nelle note quando hai trasferito le ore in un registro esterno.\
                • Non includere mese/anno nel titolo: l’app archivia automaticamente.
                """)
            }
            .padding()
        }
        .background(Color.white)
        .cornerRadius(12)
        .padding()
        .overlay(
            Button("Chiudi") {
                onDismiss()
            }
            .font(.title2)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .cornerRadius(8)
            .padding(.horizontal),
            alignment: .bottom
        )
    }
}

// MARK: - Project Manager View
struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager

    @State private var newProjectName = ""
    @State private var showEtichetteSheet = false
    @State private var showImportSheet = false
    @State private var importError: AlertError? = nil
    @State private var pendingImportData: ImportData? = nil
    @State private var showImportConfirmation = false

    @State private var showHowItWorksSheet = false
    @State private var showHowItWorksButton = false

    @State private var editMode: EditMode = .inactive
    @State private var editingProjects = false

    @State private var showExportOptions = false
    @State private var exportURL: URL? = nil
    @State private var showActivityView = false

    struct ImportData: Codable {
        let projects: [Project]
        let backupProjects: [Project]
        let labels: [ProjectLabel]
        let lockedLabelID: String?
    }

    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header:
                        Text("Progetti Correnti")
                            .font(.largeTitle).bold()
                            .padding(.top, 10)
                    ) {
                        let unlabeled = projectManager.projects.filter { $0.labelID == nil }
                        if !unlabeled.isEmpty {
                            ForEach(unlabeled) { p in
                                ProjectRowView(
                                  project: p,
                                  projectManager: projectManager,
                                  editingProjects: editingProjects
                                )
                            }
                            .onMove { idx, off in
                                projectManager.moveProjects(
                                  forLabel: nil,
                                  indices: idx,
                                  newOffset: off
                                )
                            }
                        }
                        ForEach(projectManager.labels) { lab in
                            LabelHeaderView(
                              label: lab,
                              projectManager: projectManager,
                              isBackup: false
                            )
                            let grp = projectManager.projects.filter { $0.labelID == lab.id }
                            if !grp.isEmpty {
                                ForEach(grp) { p in
                                    ProjectRowView(
                                      project: p,
                                      projectManager: projectManager,
                                      editingProjects: editingProjects
                                    )
                                }
                                .onMove { idx, off in
                                    projectManager.moveProjects(
                                      forLabel: lab.id,
                                      indices: idx,
                                      newOffset: off
                                    )
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
                                  editingProjects: editingProjects
                                )
                            }
                            .onMove { idx, off in
                                projectManager.moveBackupProjects(
                                  forLabel: nil,
                                  indices: idx,
                                  newOffset: off
                                )
                            }
                        }
                        ForEach(projectManager.labels) { lab in
                            let grp = projectManager.backupProjects.filter { $0.labelID == lab.id }
                            if !grp.isEmpty {
                                LabelHeaderView(
                                  label: lab,
                                  projectManager: projectManager,
                                  isBackup: true
                                )
                                ForEach(grp) { p in
                                    ProjectRowView(
                                      project: p,
                                      projectManager: projectManager,
                                      editingProjects: editingProjects
                                    )
                                }
                                .onMove { idx, off in
                                    projectManager.moveBackupProjects(
                                      forLabel: lab.id,
                                      indices: idx,
                                      newOffset: off
                                    )
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
                    Button("Crea") {
                        guard !newProjectName.isEmpty else { return }
                        projectManager.addProject(name: newProjectName)
                        newProjectName = ""
                    }
                    .font(.title3)
                    .foregroundColor(.green)
                    .padding(8)
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: 2)
                    )

                    Button("Etichette") {
                        showEtichetteSheet = true
                    }
                    .font(.title3)
                    .foregroundColor(.red)
                    .padding(8)
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red, lineWidth: 2)
                    )
                }
                .padding()

                HStack {
                    Button("Condividi Monte Ore") {
                        showExportOptions = true
                    }
                    .font(.title3)
                    .foregroundColor(.purple)
                    .padding()
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple, lineWidth: 2)
                    )

                    Spacer()

                    Button("Importa File") {
                        showImportSheet = true
                    }
                    .font(.title3)
                    .foregroundColor(.orange)
                    .padding()
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange, lineWidth: 2)
                    )
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
                        .font(.system(size: 40))
                        .bold()
                        .foregroundColor(.yellow)
                    }
                }
            }
            .sheet(isPresented: $showEtichetteSheet) {
                LabelsManagerView(projectManager: projectManager)
            }
            .confirmationDialog("Esporta Monte Ore",
                                isPresented: $showExportOptions,
                                titleVisibility: .visible) {
                Button("Backup (JSON)") {
                    exportURL = projectManager.getExportURL()
                    showActivityView = true
                }
                Button("Esporta CSV monte ore") {
                    exportURL = projectManager.getCSVExportURL()
                    showActivityView = true
                }
                Button("Annulla", role: .cancel) { }
            }
            .sheet(isPresented: $showActivityView) {
                if let url = exportURL {
                    ActivityView(activityItems: [url])
                } else {
                    Text("Errore nell'esportazione")
                }
            }
            .fileImporter(isPresented: $showImportSheet,
                          allowedContentTypes: [UTType.json]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else {
                        importError = AlertError(message: "Non è possibile accedere al file.")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        let imported = try JSONDecoder()
                          .decode(ImportData.self, from: data)
                        pendingImportData = imported
                        showImportConfirmation = true
                    } catch {
                        importError = AlertError(
                          message: "Errore nell'importazione: \(error)")
                    }
                case .failure(let error):
                    importError = AlertError(message: "Errore: \(error.localizedDescription)")
                }
            }
            .alert(item: $importError) { e in
                Alert(title: Text("Errore"),
                      message: Text(e.message),
                      dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showImportConfirmation) {
                if let pending = pendingImportData {
                    ImportConfirmationView(
                      message: "Attenzione: sovrascrivere tutto?",
                      importAction: {
                        projectManager.projects     = pending.projects
                        projectManager.backupProjects = pending.backupProjects
                        projectManager.labels        = pending.labels
                        if let l = pending.lockedLabelID,
                           let uuid = UUID(uuidString: l)
                        {
                            projectManager.lockedLabelID = uuid
                        } else {
                            projectManager.lockedLabelID = nil
                        }
                        projectManager.currentProject =
                          pending.projects.first
                        projectManager.saveProjects()
                        projectManager.saveLabels()
                        pendingImportData = nil
                        showImportConfirmation = false
                      },
                      cancelAction: {
                        pendingImportData = nil
                        showImportConfirmation = false
                      }
                    )
                } else {
                    Text("Errore: nessun dato da importare.")
                }
            }
            .sheet(isPresented: $showHowItWorksSheet,
                   onDismiss: { showHowItWorksButton = false }) {
                ComeFunzionaSheetView {
                    showHowItWorksSheet = false
                }
            }
        }
    }
}

// MARK: - Import Confirmation
struct ImportConfirmationView: View {
    let message: String
    let importAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Importa File")
                .font(.title).bold()
            Text(message)
                .multilineTextAlignment(.center)
                .padding()
            HStack {
                Button("Annulla") {
                    cancelAction()
                }
                .foregroundColor(.red)
                .padding()
                .overlay(
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red, lineWidth: 2)
                )
                Button("Importa") {
                    importAction()
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.yellow)
                .cornerRadius(8)
            }
        }
        .padding()
    }
}

// MARK: - Play Sound Placeholder
func playSound(success: Bool) {
    // AVFoundation integration if needed
}

// MARK: - App Entry
@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()

    @State private var showProjectManager = false
    @State private var showNonCHoSbattiSheet = false
    @State private var showPopup = false
    @AppStorage("medalAwarded") private var medalAwarded = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape      = geo.size.width > geo.size.height
            let showPrompt       = projectManager.currentProject == nil
            let isBackupProject  = projectManager.currentProject
              .flatMap { proj in
                projectManager.backupProjects
                  .first(where: { $0.id == proj.id })
              } != nil

            ZStack {
                Color(hex: "#54c0ff")
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 20) {
                    if showPrompt {
                        NoNotesPromptView(
                          onOk: { showProjectManager = true },
                          onNonCHoSbatti: {
                            showNonCHoSbattiSheet = true
                          }
                        )
                    } else if let project = projectManager.currentProject {
                        let bg = projectManager.isProjectRunning(project)
                                 ? Color.yellow
                                 : Color.white.opacity(0.2)

                        NoteView(
                          project: project,
                          projectManager: projectManager
                        )
                        .frame(
                          width: isLandscape
                                 ? geo.size.width
                                 : geo.size.width - 40,
                          height: isLandscape
                                 ? geo.size.height * 0.4
                                 : geo.size.height * 0.60
                        )
                        .background(bg)
                        .cornerRadius(25)
                        .clipped()
                    }

                    // 11) Split yellow button
                    ZStack {
                        Circle()
                            .fill(Color.black)
                            .frame(
                              width: isLandscape ? 100 : 140,
                              height: isLandscape ? 100 : 140
                            )
                        VStack(spacing: 0) {
                            Button {
                                previousProject()
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .padding(.top, 16)
                            }
                            Spacer()
                            Button {
                                cycleProject()
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .padding(.bottom, 16)
                            }
                        }
                        .frame(
                          width: isLandscape ? 100 : 140,
                          height: isLandscape ? 100 : 140
                        )
                    }
                    .disabled(
                      projectManager.currentProject == nil
                      || isBackupProject
                    )

                    HStack {
                        Button {
                            showProjectManager = true
                        } label: {
                            Text("Gestione\nProgetti")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.black)
                                .frame(
                                  width: isLandscape ? 90 : 140,
                                  height: isLandscape ? 100 : 140
                                )
                                .background(Circle().fill(Color.white))
                                .overlay(
                                  Circle().stroke(Color.black, lineWidth: 2)
                                )
                        }

                        Spacer()

                        Button {
                            cycleProject()
                        } label: {
                            Text("Cambia\nProgetto")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.black)
                                .frame(
                                  width: isLandscape ? 90 : 140,
                                  height: isLandscape ? 100 : 140
                                )
                                .background(Circle().fill(Color.yellow))
                                .overlay(
                                  Circle().stroke(Color.black, lineWidth: 2)
                                )
                        }
                        .disabled(
                          projectManager.currentProject == nil
                          || isBackupProject
                        )
                    }
                    .padding(
                      .horizontal,
                      isLandscape ? 10 : 30
                    )
                    .padding(
                      .bottom,
                      isLandscape ? 0 : 30
                    )
                }

                if showPopup {
                    PopupView(
                      message:
                        "Congratulazioni! Hai guadagnato la medaglia \"Sbattimenti zero eh\""
                    )
                    .transition(.scale)
                }
            }
            .sheet(isPresented: $showProjectManager) {
                ProjectManagerView(
                  projectManager: projectManager
                )
            }
            .sheet(isPresented: $showNonCHoSbattiSheet) {
                NonCHoSbattiSheetView {
                    if !medalAwarded {
                        medalAwarded = true
                        showPopup = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            withAnimation {
                                showPopup = false
                            }
                        }
                    }
                    showNonCHoSbattiSheet = false
                }
            }
        }
    }

    // Cycle forward
    func cycleProject() {
        let available: [Project] =
          projectManager.lockedLabelID.flatMap { lid in
            projectManager.projects
              .filter { $0.labelID == lid }
          } ?? projectManager.projects
        guard let cur = projectManager.currentProject,
              let idx = available.firstIndex(where: { $0.id == cur.id }),
              available.count > 1 else { return }
        projectManager.currentProject = available[(idx + 1) % available.count]
    }

    // 11) Cycle backward
    func previousProject() {
        let available: [Project] =
          projectManager.lockedLabelID.flatMap { lid in
            projectManager.projects
              .filter { $0.labelID == lid }
          } ?? projectManager.projects
        guard let cur = projectManager.currentProject,
              let idx = available.firstIndex(where: { $0.id == cur.id }),
              available.count > 1 else { return }
        projectManager.currentProject =
          available[(idx - 1 + available.count) % available.count]
    }
}

/// When no project active
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
                Button("Crea/Seleziona Progetto") {
                    onOk()
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)

                Button("Non CHo Sbatti") {
                    onNonCHoSbatti()
                }
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(8)
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
                .multilineTextAlignment(.center)
            Button("Mh") {
                onDismiss()
            }
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
