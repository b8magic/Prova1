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
    var note: String = ""
    
    enum CodingKeys: String, CodingKey {
        case id, giorno, orari, note
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        giorno = try container.decode(String.self, forKey: .giorno)
        orari = try container.decode(String.self, forKey: .orari)
        note = (try? container.decode(String.self, forKey: .note)) ?? ""
    }
    
    init(giorno: String, orari: String, note: String = "") {
        self.giorno = giorno
        self.orari = orari
        self.note = note
    }
    
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
    
    var totalProjectMinutes: Int {
        noteRows.reduce(0) { $0 + $1.totalMinutes }
    }
    
    var totalProjectTimeString: String {
        let hours = totalProjectMinutes / 60
        let minutes = totalProjectMinutes % 60
        return "\(hours)h \(minutes)m"
    }
    
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
    @Published var backupProjects: [Project] = []
    
    private let projectsFileName = "projects.json"
    
    init() {
        loadProjects()
        loadBackupProjects()
        if projects.isEmpty {
            self.projects = []
            self.currentProject = nil
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
    
    func deleteBackupProject(project: Project) {
        let fm = FileManager.default
        let url = getURLForBackup(project: project)
        try? fm.removeItem(at: url)
        if let index = backupProjects.firstIndex(where: { $0.id == project.id }) {
            backupProjects.remove(at: index)
        }
    }
    
    func isProjectRunning(_ project: Project) -> Bool {
        if let lastRow = project.noteRows.last {
            return lastRow.orari.hasSuffix("-")
        }
        return false
    }
    
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
    
    func getURLForBackup(project: Project) -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupFileName = "\(project.name).json"
        return docs.appendingPathComponent(backupFileName)
    }
    
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

// MARK: - Export & Import
struct ExportData: Codable {
    let projects: [Project]
    let backupProjects: [Project]
}
extension ProjectManager {
    func getExportURL() -> URL? {
        let exportData = ExportData(projects: projects, backupProjects: backupProjects)
        do {
            let data = try JSONEncoder().encode(exportData)
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

// MARK: - Import Confirmation View
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

// MARK: - Popup View (Medaglia)
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

// MARK: - Nuove Sheet per le Tendine

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

struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Frate, ma è una minchiata.. smanetta un po'")
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

// MARK: - NoNotesPromptView
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

// MARK: - Main Views
struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var switchAlert: ActiveAlert? = nil
    @State private var showProjectManager: Bool = false
    @State private var showNonCHoSbattiSheet: Bool = false
    @State private var showPopup: Bool = false
    // Usiamo AppStorage per mostrare la medaglia una sola volta
    @AppStorage("medalAwarded") private var medalAwarded: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            // Mostriamo il prompt solo se non esiste un progetto corrente
            let showPrompt = projectManager.currentProject == nil
            
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if showPrompt {
                        NoNotesPromptView(
                            onOk: { showProjectManager = true },
                            onNonCHoSbatti: { showNonCHoSbattiSheet = true }
                        )
                    } else {
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
                    .disabled(projectManager.currentProject == nil)
                    
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
                        .disabled(projectManager.currentProject == nil)
                    }
                    .padding(.horizontal, isLandscape ? 10 : 30)
                    .padding(.bottom, isLandscape ? 0 : 30)
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
        // Implementa la riproduzione audio con AVFoundation se desiderato.
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
    @State private var projectForDeletionMain: Project? = nil
    @State private var projectForDeletionBackup: Project? = nil
    @State private var showShareSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importError: AlertError? = nil
    @State private var pendingImportData: ExportData? = nil
    @State private var showImportConfirmationSheet: Bool = false
    // Stato per la sheet "Come funziona l'app"
    @State private var showComeFunzionaSheet: Bool = false
    // Stato per il pulsante nella toolbar
    @State private var showHowItWorksSecondButton: Bool = false

    var body: some View {
        ZStack {
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
                    }
                    .padding()
                    
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
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if showHowItWorksSecondButton {
                            Button(action: {
                                withAnimation {
                                    showComeFunzionaSheet = true
                                }
                            }) {
                                Text("Come funziona l'app")
                                    .font(.custom("Permanent Marker", size: 20))
                                    .foregroundColor(.black)
                                    .padding(8)
                                    .background(Color.yellow)
                                    .cornerRadius(8)
                            }
                        } else {
                            Button(action: {
                                withAnimation {
                                    showHowItWorksSecondButton = true
                                }
                            }) {
                                Text("?")
                                    .font(.system(size: 40))
                                    .bold()
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                }
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
                            Button("Annulla") { showRenameSheet = false }
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
                            } catch {
                                importError = AlertError(message: "Errore nell'importazione: \(error)")
                            }
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
                                projectManager.currentProject = pending.projects.first
                                projectManager.saveProjects()
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
            } // Fine NavigationView
            
            .sheet(isPresented: $showComeFunzionaSheet) {
                ComeFunzionaSheetView {
                    showComeFunzionaSheet = false
                }
            }
        }
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
