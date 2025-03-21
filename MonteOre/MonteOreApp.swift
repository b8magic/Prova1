import SwiftUI
import AVFoundation
import UniformTypeIdentifiers  // For file import/export functionality

// MARK: - Color Extension for Hex Colors
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
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

// MARK: - Alert Error Wrapper
struct AlertError: Identifiable {
    var id: String { message }
    let message: String
}

// MARK: - ActiveAlert Enum for Alert Handling
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
    var giorno: String      // e.g. "Giovedì 18/03/25"
    var orari: String       // e.g. "14:32-17:12 17:18-"
    var note: String = ""   // Additional remarks
    
    enum CodingKeys: String, CodingKey {
        case id, giorno, orari, note
    }
    
    // Custom initializer to support older exports.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        giorno = try container.decode(String.self, forKey: .giorno)
        orari = try container.decode(String.self, forKey: .orari)
        note = (try? container.decode(String.self, forKey: .note)) ?? ""
    }
    
    // Default initializer.
    init(giorno: String, orari: String, note: String = "") {
        self.giorno = giorno
        self.orari = orari
        self.note = note
    }
    
    // Compute total minutes from completed intervals.
    var totalMinutes: Int {
        let segments = orari.split(separator: " ")
        var total = 0
        for seg in segments {
            let parts = seg.split(separator: "-")
            if parts.count == 2 {
                let start = String(parts[0])
                let end = String(parts[1])
                if let startMins = minutesFromString(start),
                   let endMins = minutesFromString(end) {
                    total += max(0, endMins - startMins)
                }
            }
        }
        return total
    }
    
    var totalTimeString: String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m"
    }
    
    // Helper: convert "HH:mm" into total minutes.
    func minutesFromString(_ timeStr: String) -> Int? {
        let parts = timeStr.split(separator: ":")
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
            return h * 60 + m
        }
        return nil
    }
}

class Project: Identifiable, ObservableObject, Codable {
    var id = UUID()
    @Published var name: String
    @Published var noteRows: [NoteRow]
    
    enum CodingKeys: CodingKey {
        case id, name, noteRows
    }
    
    init(name: String) {
        self.name = name
        self.noteRows = []
    }
    
    // MARK: - Codable Conformance
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        noteRows = try container.decode([NoteRow].self, forKey: .noteRows)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(noteRows, forKey: .noteRows)
    }
    
    // Total minutes for the entire project.
    var totalProjectMinutes: Int {
        noteRows.reduce(0) { $0 + $1.totalMinutes }
    }
    
    var totalProjectTimeString: String {
        let hours = totalProjectMinutes / 60
        let minutes = totalProjectMinutes % 60
        return "\(hours)h \(minutes)m"
    }
    
    // Helper: parse the "giorno" string into a Date.
    func dateFromGiorno(_ giorno: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE dd/MM/yy"
        return formatter.date(from: giorno)
    }
}

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var currentProject: Project?
    @Published var backupProjects: [Project] = []  // Holds backup (past month) projects.
    
    // File‑based saving.
    private let projectsFileName = "projects.json"
    
    init() {
        loadProjects()
        loadBackupProjects()  // Load backups.
        if projects.isEmpty {
            let defaultProject = Project(name: "Progetto 1")
            self.projects = [defaultProject]
            self.currentProject = defaultProject
            saveProjects()
        } else {
            self.currentProject = projects.first
        }
    }
    
    func addProject(name: String) {
        let newProj = Project(name: name)
        projects.append(newProj)
        currentProject = newProj
        saveProjects()
    }
    
    func renameProject(project: Project, newName: String) {
        project.name = newName
        saveProjects()
    }
    
    func deleteProject(project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: index)
            if currentProject?.id == project.id {
                currentProject = projects.first
            }
            saveProjects()
        }
    }
    
    // Delete a backup project.
    func deleteBackupProject(project: Project) {
        let fm = FileManager.default
        let url = getURLForBackup(project: project)
        try? fm.removeItem(at: url)
        if let index = backupProjects.firstIndex(where: { $0.id == project.id }) {
            backupProjects.remove(at: index)
        }
    }
    
    // A project is “in corso” (running) if its last note row's orari ends with a dash.
    func isProjectRunning(_ project: Project) -> Bool {
        if let lastRow = project.noteRows.last {
            return lastRow.orari.hasSuffix("-")
        }
        return false
    }
    
    // MARK: - File Persistence Methods
    
    func getProjectsFileURL() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(projectsFileName)
    }
    
    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: getProjectsFileURL())
        } catch {
            print("Error saving projects: \(error)")
        }
    }
    
    func loadProjects() {
        let url = getProjectsFileURL()
        if let data = try? Data(contentsOf: url),
           let savedProjects = try? JSONDecoder().decode([Project].self, from: data) {
            self.projects = savedProjects
        }
    }
    
    // Return URL for a backup file.
    func getURLForBackup(project: Project) -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupFileName = "\(project.name).json"
        return docs.appendingPathComponent(backupFileName)
    }
    
    // Backup current project when new month starts.
    func backupCurrentProjectIfNeeded(_ project: Project, currentDate: Date, currentGiorno: String) {
        if let lastRow = project.noteRows.last,
           lastRow.giorno != currentGiorno,
           let lastDate = project.dateFromGiorno(lastRow.giorno) {
            let calendar = Calendar.current
            let lastMonth = calendar.component(.month, from: lastDate)
            let currentMonth = calendar.component(.month, from: currentDate)
            if currentMonth != lastMonth {
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "it_IT")
                dateFormatter.dateFormat = "LLLL"
                let monthName = dateFormatter.string(from: lastDate).capitalized
                let yearSuffix = String(calendar.component(.year, from: lastDate) % 100)
                let backupName = "\(project.name) \(monthName) \(yearSuffix)"
                
                let backupProject = Project(name: backupName)
                backupProject.noteRows = project.noteRows
                let backupURL = getURLForBackup(project: backupProject)
                do {
                    let data = try JSONEncoder().encode(backupProject)
                    try data.write(to: backupURL)
                    print("Backup created at: \(backupURL)")
                } catch {
                    print("Error creating backup: \(error)")
                }
                loadBackupProjects()
                project.noteRows.removeAll()
                saveProjects()
            }
        }
    }
    
    // Load backup projects.
    func loadBackupProjects() {
        backupProjects = []
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let files = try fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: [])
            for file in files {
                if file.lastPathComponent != projectsFileName && file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let backup = try? JSONDecoder().decode(Project.self, from: data) {
                        backupProjects.append(backup)
                    }
                }
            }
        } catch {
            print("Error loading backup projects: \(error)")
        }
    }
}

// MARK: - Export Data Model and Export Method (CHANGED)
// New export data model to combine both current and backup projects.
struct ExportData: Codable {
    let projects: [Project]
    let backupProjects: [Project]
}

extension ProjectManager {
    // New method to get the export URL for combined projects.
    func getExportURL() -> URL? {
        let exportData = ExportData(projects: projects, backupProjects: backupProjects)
        do {
            let data = try JSONEncoder().encode(exportData)
            // Save to a temporary file.
            let tempDir = FileManager.default.temporaryDirectory
            let exportURL = tempDir.appendingPathComponent("MonteOreExport.json")
            try data.write(to: exportURL)
            return exportURL
        } catch {
            print("Error exporting data: \(error)")
            return nil
        }
    }
}

// MARK: - Delete Confirmation View

struct DeleteConfirmationView: View {
    let projectName: String
    let deleteAction: () -> Void
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Elimina Progetto")
                .font(.title)
                .bold()
            Text("Sei sicuro di voler eliminare il progetto \"\(projectName)\"?")
                .multilineTextAlignment(.center)
                .padding()
            Button(action: {
                deleteAction()
                presentationMode.wrappedValue.dismiss()
            }) {
                Text("Elimina")
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

// MARK: - Main Views

struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var switchAlert: ActiveAlert? = nil
    @State private var showProjectManager: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isBackup = projectManager.currentProject.map { cp in
                projectManager.backupProjects.contains(where: { $0.id == cp.id })
            } ?? false
            
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if let project = projectManager.currentProject {
                        ScrollView {
                            NoteView(project: project)
                                .padding()
                        }
                        .frame(width: isLandscape ? geometry.size.width : geometry.size.width - 40,
                               height: isLandscape ? geometry.size.height * 0.4 : geometry.size.height * 0.60)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(25)
                        .clipped()
                    }
                    
                    Button(action: {
                        mainButtonTapped()
                    }) {
                        Text("Pigia il tempo")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                            .background(Circle().fill(Color.black))
                    }
                    .disabled(isBackup)
                    
                    HStack {
                        Button(action: {
                            showProjectManager = true
                        }) {
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
                        
                        Button(action: {
                            cycleProject()
                        }) {
                            Text("Cambia\nProgetto")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.black)
                                .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                                .background(Circle().fill(Color.white))
                                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        }
                        .background(Color(hex: "#54c0ff"))
                        .disabled(isBackup)
                    }
                    .padding(.horizontal, isLandscape ? 10 : 30)
                    .padding(.bottom, isLandscape ? 0 : 30)
                }
            }
            .sheet(isPresented: $showProjectManager) {
                ProjectManagerView(projectManager: projectManager)
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
        guard let current = projectManager.currentProject else { return }
        if !projectManager.projects.contains(where: { $0.id == current.id }) {
            if let firstMain = projectManager.projects.first {
                projectManager.currentProject = firstMain
            }
            return
        }
        guard let currentIndex = projectManager.projects.firstIndex(where: { $0.id == current.id }),
              projectManager.projects.count > 1 else { return }
        let nextIndex = (currentIndex + 1) % projectManager.projects.count
        let nextProject = projectManager.projects[nextIndex]
        if projectManager.isProjectRunning(current) {
            let running = projectManager.projects.filter { projectManager.isProjectRunning($0) }
            let names = running.map { $0.name }.joined(separator: ", ")
            let message = "Attenzione: il tempo sta ancora scorrendo per i seguenti progetti: \(names). Vuoi continuare?"
            switchAlert = .running(newProject: nextProject, message: message)
        } else {
            projectManager.currentProject = nextProject
        }
    }
    
    func mainButtonTapped() {
        guard let project = projectManager.currentProject else {
            playSound(success: false)
            return
        }
        if projectManager.backupProjects.contains(where: { $0.id == project.id }) { return }
        
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "it_IT")
        dateFormatter.dateFormat = "EEEE dd/MM/yy"
        let giornoStr = dateFormatter.string(from: now).capitalized
        
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "it_IT")
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: now)
        
        projectManager.backupCurrentProjectIfNeeded(project, currentDate: now, currentGiorno: giornoStr)
        
        if project.noteRows.isEmpty || project.noteRows.last?.giorno != giornoStr {
            let newRow = NoteRow(giorno: giornoStr, orari: timeStr + "-", note: "")
            project.noteRows.append(newRow)
        } else {
            guard var lastRow = project.noteRows.popLast() else { return }
            if lastRow.orari.hasSuffix("-") {
                lastRow.orari += timeStr
            } else {
                lastRow.orari += " " + timeStr + "-"
            }
            project.noteRows.append(lastRow)
        }
        projectManager.saveProjects()
        playSound(success: true)
    }
    
    func playSound(success: Bool) {
        // Implement sound playing using AVFoundation if desired.
    }
}

struct NoteView: View {
    @ObservedObject var project: Project
    @State private var editMode: Bool = false
    @State private var editedRows: [NoteRow] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(project.name)
                        .font(.title3)
                        .bold()
                    Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                        .font(.title3)
                        .bold()
                }
                Spacer()
                if editMode {
                    VStack {
                        Button("Salva") {
                            project.noteRows = editedRows
                            editMode = false
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
            
            if editMode {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($editedRows) { $row in
                            HStack(spacing: 8) {
                                TextField("Giorno", text: $row.giorno)
                                    .font(.system(size: 17))
                                    .frame(height: 60)
                                Divider().frame(height: 60).background(Color.black)
                                TextEditor(text: $row.orari)
                                    .font(.system(size: 17))
                                    .frame(height: 60)
                                Divider().frame(height: 60).background(Color.black)
                                Text(row.totalTimeString)
                                    .font(.system(size: 17))
                                    .frame(height: 60)
                                Divider().frame(height: 60).background(Color.black)
                                TextField("Note", text: $row.note)
                                    .font(.system(size: 17))
                                    .frame(height: 60)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(project.noteRows) { row in
                            HStack(spacing: 8) {
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
        }
        .padding(20)
    }
}

struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @State private var newProjectName: String = ""
    @State private var showRenameSheet: Bool = false
    @State private var projectToRename: Project? = nil
    @State private var renameNewName: String = ""
    // Separate state variables for deletion sheets.
    @State private var projectForDeletionMain: Project? = nil
    @State private var projectForDeletionBackup: Project? = nil
    
    // Updated state for file sharing and importing.
    @State private var showShareSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importError: AlertError? = nil
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header: Text("Progetti Correnti")) {
                        ForEach(projectManager.projects) { project in
                            HStack {
                                Button(action: {
                                    projectManager.currentProject = project
                                }) {
                                    Text(project.name)
                                        .font(.title3)
                                }
                                Spacer()
                                // Rinomina button.
                                Button(action: {
                                    projectToRename = project
                                    renameNewName = project.name
                                    showRenameSheet = true
                                }) {
                                    Text("Rinomina")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                // Elimina button opens deletion sheet.
                                Button(action: {
                                    projectForDeletionMain = project
                                }) {
                                    Text("Elimina")
                                        .font(.title3)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    Section(header: VStack {
                        Divider()
                        Text("Mensilità passate")
                    }) {
                        ForEach(projectManager.backupProjects) { project in
                            HStack {
                                Button(action: {
                                    projectManager.currentProject = project
                                }) {
                                    Text(project.name)
                                        .font(.title3)
                                }
                                Spacer()
                                // Elimina button for backup.
                                Button(action: {
                                    projectForDeletionBackup = project
                                }) {
                                    Text("Elimina")
                                        .font(.title3)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(PlainListStyle())
                
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
                }
                .padding()
                
                // Updated Share Button (CHANGED)
                Button(action: {
                    showShareSheet = true
                }) {
                    Text("Condividi Monte Ore")
                        .font(.title3)
                        .foregroundColor(.purple)
                        .padding()
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 2))
                }
                .padding(.bottom, 10)
                
                Button(action: {
                    showImportSheet = true
                }) {
                    Text("Importa File")
                        .font(.title3)
                        .foregroundColor(.orange)
                        .padding()
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2))
                }
                .padding(.bottom, 10)
            }
            .navigationTitle("Gestione Progetti")
            .sheet(item: $projectForDeletionMain) { project in
                DeleteConfirmationView(projectName: project.name) {
                    projectManager.deleteProject(project: project)
                }
            }
            .sheet(item: $projectForDeletionBackup) { project in
                DeleteConfirmationView(projectName: project.name) {
                    projectManager.deleteBackupProject(project: project)
                }
            }
            .sheet(isPresented: $showRenameSheet) {
                VStack(spacing: 20) {
                    Text("Rinomina Progetto")
                        .font(.title)
                    TextField("Nuovo nome", text: $renameNewName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    HStack(spacing: 40) {
                        Button("Annulla") {
                            showRenameSheet = false
                        }
                        Button("OK") {
                            if let project = projectToRename {
                                projectManager.renameProject(project: project, newName: renameNewName)
                            }
                            showRenameSheet = false
                        }
                    }
                    .font(.title2)
                    Spacer()
                }
                .padding()
            }
            // Updated share sheet (CHANGED) to use getExportURL() and import ExportData.
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
                    do {
                        let data = try Data(contentsOf: url)
                        let importedData = try JSONDecoder().decode(ExportData.self, from: data)
                        if confirmOverwrite() {
                            projectManager.projects = importedData.projects
                            projectManager.backupProjects = importedData.backupProjects
                            projectManager.currentProject = importedData.projects.first
                            projectManager.saveProjects()
                        }
                    } catch {
                        importError = AlertError(message: "Errore nell'importazione: \(error)")
                    }
                case .failure(let error):
                    importError = AlertError(message: "Errore: \(error.localizedDescription)")
                }
            }
            .alert(item: $importError) { error in
                Alert(title: Text("Errore"), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
        }
    }
    
    func confirmOverwrite() -> Bool {
        print("Attenzione: sei sicuro di voler sovrascrivere il file corrente? Tutti i progetti saranno persi.")
        return true
    }
}

struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                   applicationActivities: applicationActivities)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}



