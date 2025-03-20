import SwiftUI
import AVFoundation

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

// MARK: - Data Models

struct NoteRow: Identifiable, Codable {
    var id = UUID()
    var giorno: String      // e.g. "Giovedì 18/03/25"
    var orari: String       // e.g. "14:32-17:12 17:18-"
    
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
}

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var currentProject: Project?
    
    init() {
        // Load saved projects if available.
        if let data = UserDefaults.standard.data(forKey: "projects"),
           let savedProjects = try? JSONDecoder().decode([Project].self, from: data) {
            self.projects = savedProjects
            self.currentProject = self.projects.first
        } else {
            // Create a default project if none are saved.
            let defaultProject = Project(name: "Progetto 1")
            self.projects = [defaultProject]
            self.currentProject = defaultProject
            saveProjects()
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
    
    // A project is “in corso” (running) if its last note row's orari ends with a dash.
    func isProjectRunning(_ project: Project) -> Bool {
        if let lastRow = project.noteRows.last {
            return lastRow.orari.hasSuffix("-")
        }
        return false
    }
    
    // Save projects persistently using UserDefaults.
    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(data, forKey: "projects")
        } catch {
            print("Error saving projects: \(error)")
        }
    }
}

// MARK: - Alert Enum for Switching/Deleting Projects

enum ActiveAlert: Identifiable {
    case delete(project: Project)
    case running(newProject: Project, message: String)
    
    var id: Int {
        switch self {
        case .delete(let project):
            return project.id.hashValue
        case .running(let newProject, _):
            return newProject.id.hashValue
        }
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
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if let project = projectManager.currentProject {
                        // Note container adjusts width and height in landscape.
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
                    
                    // Spacer()
                    
                    // Main button (scales slightly in landscape)
                    Button(action: {
                        mainButtonTapped()
                    }) {
                        Text("Pigia il tempo")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                            .background(Circle().fill(Color.black))
                    }
                    
                    // Bottom buttons
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
                        .background(Color(hex: "#54c0ff")) // Fa sì che non si veda il quadrato
                        
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
                        .background(Color(hex: "#54c0ff")) // Fa sì che non si veda il quadrato
                    }
                    .padding(.horizontal, isLandscape ? 10 : 30)
                    .padding(.bottom, isLandscape ? 0 : 30)
                }
            }
            .sheet(isPresented: $showProjectManager) {
                ProjectManagerView(projectManager: projectManager)
            }
            .alert(item: $switchAlert) { alert in
                switch alert {
                case .running(let newProject, let message):
                    return Alert(title: Text("Attenzione"),
                                 message: Text(message),
                                 primaryButton: .default(Text("Continua"), action: {
                                    projectManager.currentProject = newProject
                                 }),
                                 secondaryButton: .cancel())
                default:
                    return Alert(title: Text("Errore"))
                }
            }
        }
    }
    
    // Cycle to the next project.
    func cycleProject() {
        guard let current = projectManager.currentProject,
              let currentIndex = projectManager.projects.firstIndex(where: { $0.id == current.id }),
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
    
    // Log time for the current project.
    func mainButtonTapped() {
        guard let project = projectManager.currentProject else {
            playSound(success: false)
            return
        }
        
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "it_IT")
        dateFormatter.dateFormat = "EEEE dd/MM/yy"
        let giornoStr = dateFormatter.string(from: now).capitalized
        
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "it_IT")
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: now)
        
        if project.noteRows.isEmpty || project.noteRows.last?.giorno != giornoStr {
            let newRow = NoteRow(giorno: giornoStr, orari: timeStr + "-")
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
    
    // Placeholder for sound effects.
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
            // Header with project name and total time in two lines.
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
                // Edit mode: cells with fixed height and 1pt larger font.
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
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Read-only mode: cells with slightly larger font.
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
    @State private var activeAlert: ActiveAlert? = nil
    @State private var showShareSheet: Bool = false
    @State private var shareText: String = ""
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.projects) { project in
                        HStack {
                            // Select project.
                            Button(action: {
                                switchProject(to: project)
                            }) {
                                Text(project.name)
                                    .font(.title3)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Rename button.
                            Button(action: {
                                projectToRename = project
                                renameNewName = project.name
                                showRenameSheet = true
                            }) {
                                Text("Rinomina")
                                    .font(.title3)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .frame(width: 100, alignment: .center)
                            
                            // Delete button.
                            Button(action: {
                                activeAlert = .delete(project: project)
                            }) {
                                Text("Elimina")
                                    .font(.title3)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .frame(width: 100, alignment: .center)
                        }
                        .padding(.vertical, 4)
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
                
                // "Condividi Monte Ore" button.
                Button(action: {
                    shareText = generateShareText()
                    showShareSheet = true
                }) {
                    Text("Condividi Monte Ore")
                        .font(.title3)
                        .foregroundColor(.purple)
                        .padding()
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 2))
                }
                .padding(.bottom, 10)
            }
            .navigationTitle("Gestione Progetti")
            .alert(item: $activeAlert) { alert in
                switch alert {
                case .delete(let project):
                    return Alert(title: Text("Elimina Progetto"),
                                 message: Text("Confermi l'eliminazione del progetto \(project.name)?"),
                                 primaryButton: .destructive(Text("Elimina"), action: {
                                    projectManager.deleteProject(project: project)
                                 }),
                                 secondaryButton: .cancel())
                case .running(let newProject, let message):
                    return Alert(title: Text("Attenzione"),
                                 message: Text(message),
                                 primaryButton: .default(Text("Continua"), action: {
                                    projectManager.currentProject = newProject
                                 }),
                                 secondaryButton: .cancel())
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
            .sheet(isPresented: $showShareSheet) {
                ActivityView(activityItems: [shareText])
            }
        }
    }
    
    func switchProject(to newProject: Project) {
        if let current = projectManager.currentProject,
           current.id != newProject.id,
           projectManager.isProjectRunning(current) {
            let running = projectManager.projects.filter { projectManager.isProjectRunning($0) }
            let names = running.map { $0.name }.joined(separator: ", ")
            let message = "Attenzione: il tempo sta ancora scorrendo per i seguenti progetti: \(names). Vuoi continuare?"
            activeAlert = .running(newProject: newProject, message: message)
        } else {
            projectManager.currentProject = newProject
        }
    }
    
    func generateShareText() -> String {
        var text = ""
        for project in projectManager.projects {
            text += "\(project.name), Totale Ore: \(project.totalProjectTimeString)\n"
            for row in project.noteRows {
                text += "\(row.giorno), \(row.orari), \(row.totalTimeString)\n"
            }
            text += "\n"
        }
        return text
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


