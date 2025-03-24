import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

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
                  red: Double(r)/255,
                  green: Double(g)/255,
                  blue: Double(b)/255,
                  opacity: Double(a)/255)
    }
}

// MARK: - PopupView
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

// New label model
struct ProjectLabel: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var colorHex: String // e.g. "#FF0000"
}

// NoteRow model remains as before.
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

// Updated Project model with an optional labelID.
class Project: Identifiable, ObservableObject, Codable {
    var id = UUID()
    @Published var name: String
    @Published var noteRows: [NoteRow]
    @Published var labelID: UUID? // New: which label (if any) the project is assigned to
    
    enum CodingKeys: CodingKey {
        case id, name, noteRows, labelID
    }
    
    init(name: String) {
        self.name = name
        self.noteRows = []
        self.labelID = nil
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

// MARK: - Project Manager

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var backupProjects: [Project] = []
    @Published var labels: [ProjectLabel] = [] // Labels list
    @Published var lockedLabel: UUID? {         // Persist locked label state
        didSet {
            if let locked = lockedLabel {
                UserDefaults.standard.set(locked.uuidString, forKey: "lockedLabel")
            } else {
                UserDefaults.standard.removeObject(forKey: "lockedLabel")
            }
        }
    }
    @Published var currentProject: Project? {   // Persist last-opened project
        didSet {
            if let cp = currentProject {
                UserDefaults.standard.set(cp.id.uuidString, forKey: "lastProjectId")
            }
        }
    }
    
    private let projectsFileName = "projects.json"
    private let labelsFileName = "labels.json"
    
    init() {
        loadProjects()
        loadBackupProjects()
        loadLabels()
        // Load lockedLabel from UserDefaults
        if let lockedString = UserDefaults.standard.string(forKey: "lockedLabel"),
           let uuid = UUID(uuidString: lockedString) {
            self.lockedLabel = uuid
        }
        // Load last opened project
        if let lastId = UserDefaults.standard.string(forKey: "lastProjectId"),
           let lastProject = projects.first(where: { $0.id.uuidString == lastId }) {
            self.currentProject = lastProject
        } else {
            self.currentProject = projects.first
        }
        
        if projects.isEmpty {
            self.projects = []
            self.currentProject = nil
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
    
    // MARK: Label management
    
    func saveLabels() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(labelsFileName)
        do {
            let data = try JSONEncoder().encode(labels)
            try data.write(to: url)
        } catch {
            print("Error saving labels: \(error)")
        }
    }
    
    func loadLabels() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(labelsFileName)
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([ProjectLabel].self, from: data) {
            self.labels = loaded
        }
    }
    
    func addLabel(title: String, colorHex: String) {
        let newLabel = ProjectLabel(title: title, colorHex: colorHex)
        labels.append(newLabel)
        saveLabels()
    }
    
    func renameLabel(label: ProjectLabel, newTitle: String) {
        if let index = labels.firstIndex(of: label) {
            labels[index].title = newTitle
            saveLabels()
        }
    }
    
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll { $0.id == label.id }
        // Remove label from any projects that had it.
        for project in projects {
            if project.labelID == label.id {
                project.labelID = nil
            }
        }
        saveLabels()
        saveProjects()
    }
    
    // Return current projects (filter by locked label if set).
    func currentProjects() -> [Project] {
        if let lock = lockedLabel {
            return projects.filter { $0.labelID == lock }
        } else {
            return projects
        }
    }
    
    // Cycle through projects (if locked, only those).
    func cycleProject() {
        let available = currentProjects()
        guard let current = currentProject, !available.isEmpty else { return }
        if !available.contains(where: { $0.id == current.id }) {
            currentProject = available.first
            return
        }
        if let currentIndex = available.firstIndex(where: { $0.id == current.id }),
           available.count > 1 {
            let nextIndex = (currentIndex + 1) % available.count
            currentProject = available[nextIndex]
        }
    }
}

// MARK: Export & Import
struct ExportData: Codable {
    let projects: [Project]
    let backupProjects: [Project]
    let labels: [ProjectLabel]
}
extension ProjectManager {
    func getExportURL() -> URL? {
        let exportData = ExportData(projects: projects, backupProjects: backupProjects, labels: labels)
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

// MARK: - Views

// A generic confirmation sheet using the same style as the original delete confirmation.
struct ConfirmationSheet: View {
    var title: String
    var message: String
    var defaultText: String = ""
    var confirmAction: (String) -> Void = { _ in }
    var cancelAction: () -> Void = { }
    var confirmButtonColor: Color = .red
    
    @State private var inputText: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title)
                .bold()
            if !defaultText.isEmpty {
                TextField("Inserisci...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
            } else {
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            HStack(spacing: 40) {
                Button("Annulla") {
                    cancelAction()
                }
                .font(.title2)
                .foregroundColor(.red)
                Button("OK") {
                    let text = inputText.isEmpty ? defaultText : inputText
                    confirmAction(text)
                }
                .font(.title2)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(confirmButtonColor)
                .cornerRadius(8)
            }
        }
        .padding()
    }
}

// Project modification sheet – using consistent confirmation style.
struct ProjectModificationSheet: View {
    let project: Project
    @ObservedObject var projectManager: ProjectManager
    @Binding var isPresented: Bool
    @State private var showRename = false
    @State private var showLabelAssign = false
    @State private var showDelete = false
    @State private var newName = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Button("Rinomina progetto") {
                newName = project.name
                showRename = true
            }
            .font(.title2)
            .foregroundColor(.blue)
            Button("Applica o revoca etichetta") {
                showLabelAssign = true
            }
            .font(.title2)
            .foregroundColor(.blue)
            Button("Elimina progetto") {
                showDelete = true
            }
            .font(.title2)
            .foregroundColor(.red)
            Button("Annulla") {
                isPresented = false
            }
            .font(.title2)
            .foregroundColor(.gray)
        }
        .padding()
        .sheet(isPresented: $showRename) {
            ConfirmationSheet(title: "Rinomina progetto",
                              message: "Inserisci il nuovo nome",
                              defaultText: newName,
                              confirmAction: { text in
                                  projectManager.renameProject(project: project, newName: text)
                                  isPresented = false
                              },
                              cancelAction: {
                                  isPresented = false
                              },
                              confirmButtonColor: .blue)
        }
        .sheet(isPresented: $showLabelAssign) {
            LabelAssignmentView(project: project, projectManager: projectManager, isPresented: $showLabelAssign)
        }
        .sheet(isPresented: $showDelete) {
            ConfirmationSheet(title: "Elimina progetto",
                              message: "Sei sicuro di voler eliminare il progetto \"\(project.name)\"?",
                              confirmAction: { _ in
                                  projectManager.deleteProject(project: project)
                                  isPresented = false
                              },
                              cancelAction: {
                                  isPresented = false
                              },
                              confirmButtonColor: .red)
        }
    }
}

// Label assignment view
struct LabelAssignmentView: View {
    @ObservedObject var project: Project
    @ObservedObject var projectManager: ProjectManager
    @Binding var isPresented: Bool
    @State private var selectedLabelID: UUID?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Assegna o revoca etichetta")
                .font(.title)
                .bold()
            Picker("Etichetta", selection: $selectedLabelID) {
                Text("Nessuna").tag(UUID?.none)
                ForEach(projectManager.labels) { label in
                    HStack {
                        Circle()
                            .fill(Color(hex: label.colorHex))
                            .frame(width: 20, height: 20)
                        Text(label.title)
                    }
                    .tag(Optional(label.id))
                }
            }
            .pickerStyle(WheelPickerStyle())
            Button("Applica") {
                project.labelID = selectedLabelID
                projectManager.saveProjects()
                isPresented = false
            }
            .font(.title2)
            .foregroundColor(.green)
            Button("Annulla") {
                isPresented = false
            }
            .font(.title2)
            .foregroundColor(.red)
        }
        .padding()
        .onAppear {
            selectedLabelID = project.labelID
        }
    }
}

// Lock info view
struct LockInfoView: View {
    let label: ProjectLabel
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Il bottone Giallo è agganciato ai progetti dell'etichetta \"\(label.title)\"")
                .multilineTextAlignment(.center)
            Button(action: onClose) {
                Text("Chiudi")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(8)
            }
        }
        .padding()
    }
}

// Label management view – appears immediately inside Gestione Progetti.
struct LabelManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newLabelTitle = ""
    @State private var newLabelColor = Color.blue
    @State private var editLabel: ProjectLabel? = nil
    @State private var editLabelTitle = ""
    
    var body: some View {
        NavigationView {
            VStack {
                Text("Etichette")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top)
                List {
                    ForEach(projectManager.labels) { label in
                        HStack {
                            Circle()
                                .fill(Color(hex: label.colorHex))
                                .frame(width: 20, height: 20)
                            Text(label.title)
                                .font(.title3)
                            Spacer()
                            Button("Rinomina") {
                                editLabel = label
                                editLabelTitle = label.title
                            }
                            .foregroundColor(.blue)
                            Button("Elimina") {
                                projectManager.deleteLabel(label: label)
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
                .listStyle(PlainListStyle())
                HStack {
                    TextField("Nuova etichetta", text: $newLabelTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    ColorPicker("", selection: $newLabelColor)
                        .labelsHidden()
                    Button("Crea") {
                        let hex = newLabelColor.toHex() ?? "#000000"
                        projectManager.addLabel(title: newLabelTitle, colorHex: hex)
                        newLabelTitle = ""
                    }
                    .foregroundColor(.green)
                }
                .padding()
            }
            .navigationTitle("Gestione Etichette")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Chiudi") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(item: $editLabel) { label in
                VStack(spacing: 20) {
                    Text("Rinomina etichetta")
                        .font(.title)
                    TextField("Nuovo nome", text: $editLabelTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    HStack(spacing: 40) {
                        Button("Annulla") { editLabel = nil }
                            .foregroundColor(.red)
                        Button("OK") {
                            projectManager.renameLabel(label: label, newTitle: editLabelTitle)
                            editLabel = nil
                        }
                        .foregroundColor(.blue)
                    }
                    .font(.title2)
                }
                .padding()
            }
        }
    }
}

// Extension to convert Color to HEX string.
extension Color {
    func toHex() -> String? {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let rgb = (Int)(r*255)<<16 | (Int)(g*255)<<8 | (Int)(b*255)
            return String(format:"#%06x", rgb)
        }
        #endif
        return nil
    }
}

// MARK: - Main App View (ContentView)
// This view remains as before: it shows the active project's note view (or a prompt if no project exists).
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
            
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    if projectManager.currentProject == nil {
                        NoNotesPromptView(
                            onOk: { showProjectManager = true },
                            onNonCHoSbatti: { showNonCHoSbattiSheet = true }
                        )
                    } else {
                        // Show the active project’s notes (unchanged from your original code)
                        ScrollView {
                            NoteView(project: projectManager.currentProject!)
                                .padding()
                        }
                        .frame(width: isLandscape ? geometry.size.width : geometry.size.width - 40,
                               height: isLandscape ? geometry.size.height * 0.60 : geometry.size.height * 0.65)
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
                    .disabled(projectManager.currentProject == nil)
                    
                    HStack {
                        Button(action: {
                            showProjectManager = true
                        }) {
                            Text("Gestione progetti")
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
                            projectManager.cycleProject()
                        }) {
                            Text("Cambia progetto")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.black)
                                .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                                .background(Circle().fill(Color(hex: "#F7CE46")))
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
                ProjectManagerView(projectManager: projectManager,
                                    showLabelManager: .constant(true),
                                    projectModificationFor: .constant(nil))
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
}

// A simple NoteView showing a project's notes (kept identical to your original version)
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

@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
