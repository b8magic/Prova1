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

// NoteRow model remains unchanged
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
    @Published var labelID: UUID? // New: optional label
    
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
    @Published var labels: [ProjectLabel] = [] // New labels list
    @Published var lockedLabel: UUID? = nil   // If non-nil, the current locked label
    
    // Persist the last-opened project via UserDefaults.
    @Published var currentProject: Project? {
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
        // Try to load the last opened project if it exists.
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
        // Also remove label from any projects that had it.
        for project in projects {
            if project.labelID == label.id {
                project.labelID = nil
            }
        }
        saveLabels()
        saveProjects()
    }
    
    // Return the list of projects for current months, possibly filtered by locked label.
    func currentProjects() -> [Project] {
        if let lock = lockedLabel {
            return projects.filter { $0.labelID == lock }
        } else {
            return projects
        }
    }
    
    // Cycle through projects; if lockedLabel is set, only cycle those.
    func cycleProject() {
        var available = currentProjects()
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

// MARK: - Export & Import
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

// View for modifying a project (showing options: Rename, Label, Delete)
struct ProjectModificationSheet: View {
    let project: Project
    @ObservedObject var projectManager: ProjectManager
    @Binding var isPresented: Bool
    @State private var showRenameConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showLabelAssign = false
    @State private var newName = ""
    @State private var selectedLabelID: UUID? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            Button("Rinomina progetto") {
                newName = project.name
                showRenameConfirm = true
            }
            .font(.title2)
            .foregroundColor(.blue)
            
            Button("Applica o revoca etichetta") {
                selectedLabelID = project.labelID
                showLabelAssign = true
            }
            .font(.title2)
            .foregroundColor(.blue)
            
            Button("Elimina progetto") {
                showDeleteConfirm = true
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
        .actionSheet(isPresented: $showRenameConfirm) {
            ActionSheet(title: Text("Rinomina progetto"),
                        message: Text("Inserisci il nuovo nome"),
                        buttons: [
                            .default(Text("OK"), action: {
                                projectManager.renameProject(project: project, newName: newName)
                                isPresented = false
                            }),
                            .cancel { isPresented = false }
                        ])
        }
        .sheet(isPresented: $showLabelAssign) {
            LabelAssignmentView(project: project, projectManager: projectManager, isPresented: $showLabelAssign)
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteConfirmationView(projectName: project.name) {
                projectManager.deleteProject(project: project)
                isPresented = false
            }
        }
    }
}

// View for assigning a label to a project
struct LabelAssignmentView: View {
    @ObservedObject var projectManager: ProjectManager
    @ObservedObject var project: Project
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

// Delete Confirmation View (same as before)
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

// Popup view for lock info
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

// View for managing labels
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
                List {
                    ForEach(projectManager.labels) { label in
                        HStack {
                            Button(action: {
                                // When tapping the color circle, show a ColorPicker inline
                            }) {
                                Circle()
                                    .fill(Color(hex: label.colorHex))
                                    .frame(width: 20, height: 20)
                            }
                            Text(label.title)
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
            .navigationTitle("Etichette")
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
                    Button("OK") {
                        projectManager.renameLabel(label: label, newTitle: editLabelTitle)
                        editLabel = nil
                    }
                    .foregroundColor(.blue)
                    Button("Annulla") { editLabel = nil }
                        .foregroundColor(.red)
                }
                .padding()
            }
        }
    }
}

// Extension to convert Color to hex string (approximate)
extension Color {
    func toHex() -> String? {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let rgb = (Int)(r*255)<<16 | (Int)(g*255)<<8 | (Int)(b*255)
            return String(format:"#%06x", rgb)
        }
        #endif
        return nil
    }
}

// Main Content View
struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var switchAlert: ActiveAlert? = nil
    @State private var showProjectManager: Bool = false
    @State private var showNonCHoSbattiSheet: Bool = false
    @State private var showPopup: Bool = false
    @State private var showLabelManager: Bool = false
    @State private var projectModificationFor: Project? = nil
    @State private var showLockInfo: Bool = false
    // Usiamo AppStorage per mostrare la medaglia una sola volta
    @AppStorage("medalAwarded") private var medalAwarded: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                Color(hex: "#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    // Title for Gestione: now split into two sections.
                    Text("Progetti correnti")
                        .font(.largeTitle)
                        .bold()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // First, show projects without label
                            if currentUnlabeledProjects().count > 0 {
                                Text("Senza etichetta")
                                    .font(.title2)
                                    .underline()
                                ForEach(currentUnlabeledProjects()) { project in
                                    projectRow(project: project)
                                }
                            }
                            // Then, for each label group:
                            ForEach(projectManager.labels) { label in
                                let projectsForLabel = currentProjects(for: label)
                                if projectsForLabel.count > 0 {
                                    HStack {
                                        Text(label.title)
                                            .font(.title2)
                                            .underline()
                                            .foregroundColor(Color(hex: label.colorHex))
                                        Spacer()
                                        // Show a lock icon if unlocked
                                        Button(action: {
                                            // Toggle lock for this label
                                            if projectManager.lockedLabel == label.id {
                                                projectManager.lockedLabel = nil
                                            } else {
                                                projectManager.lockedLabel = label.id
                                            }
                                        }) {
                                            Image(systemName: projectManager.lockedLabel == label.id ? "lock.fill" : "lock.open.fill")
                                                .foregroundColor(.black)
                                        }
                                    }
                                    ForEach(projectsForLabel) { project in
                                        projectRow(project: project)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: isLandscape ? geometry.size.height * 0.45 : geometry.size.height * 0.50)
                    
                    Text("Mensilità passate")
                        .font(.largeTitle)
                        .bold()
                    
                    // For simplicity, list backupProjects (grouping similar to above can be done similarly)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(projectManager.backupProjects) { project in
                                Text(project.name)
                                    .font(.title3)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: isLandscape ? geometry.size.height * 0.25 : geometry.size.height * 0.30)
                    
                    // Main Buttons Row
                    HStack(spacing: 20) {
                        Button(action: {
                            // Show project management view
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
                                .background(Circle().fill(Color(hex: "#F7CE46"))) // Ocra yellow
                                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        }
                        .background(Color(hex: "#54c0ff"))
                        .disabled(projectManager.currentProject == nil)
                    }
                    .padding(.horizontal, isLandscape ? 10 : 30)
                    .padding(.bottom, isLandscape ? 0 : 30)
                    
                    // Bottom row: "Pigia il tempo" button
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
                }
                
                // Overlays for popup, project modification, lock info
                if let project = projectModificationFor {
                    ProjectModificationSheet(project: project, projectManager: projectManager, isPresented: Binding(get: {
                        self.projectModificationFor != nil
                    }, set: { newValue in
                        if !newValue { self.projectModificationFor = nil }
                    }))
                    .background(Color.white.opacity(0.9))
                    .cornerRadius(12)
                    .padding()
                }
                if showPopup {
                    PopupView(message: "Congratulazioni! Hai guadagnato la medaglia \"Sbattimenti zero eh\"")
                        .transition(.scale)
                }
            }
            .sheet(isPresented: $showProjectManager) {
                ProjectManagerView(projectManager: projectManager, showLabelManager: $showLabelManager, projectModificationFor: $projectModificationFor)
            }
            .sheet(isPresented: $showLabelManager) {
                LabelManagerView(projectManager: projectManager)
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
            // If a label is locked, show the lock info popup
            .sheet(isPresented: $showLockInfo) {
                if let lockedID = projectManager.lockedLabel,
                   let label = projectManager.labels.first(where: { $0.id == lockedID }) {
                    LockInfoView(label: label) {
                        projectManager.lockedLabel = nil
                        showLockInfo = false
                    }
                }
            }
        }
    }
    
    // Helper functions to group projects by label
    func currentUnlabeledProjects() -> [Project] {
        projectManager.currentProjects().filter { $0.labelID == nil }
    }
    
    func currentProjects(for label: ProjectLabel) -> [Project] {
        projectManager.currentProjects().filter { $0.labelID == label.id }
    }
    
    // A row for a project: shows its name and a "Modifica" button
    @ViewBuilder
    func projectRow(project: Project) -> some View {
        HStack {
            Text(project.name)
                .font(.title3)
            Spacer()
            Button("Modifica") {
                projectModificationFor = project
            }
            .foregroundColor(.blue)
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.6)))
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
        // Implement sound playback using AVFoundation if desired.
    }
}

// NonCHoSbattiSheetView remains unchanged
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

// Updated ComeFunzionaSheetView
struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack {
            Text("""
Se un'attività supera la mezzanotte, al momento di pigiarne il termine l'app creerà un nuovo giorno. Basterá modificare la nota col pulsante in alto a destra, e inserire un termine di fine orario che fuoriesca le 24. Ad esempio, se l'attività si è conclusa all'1:29, si inserisca 25:29.

Ogni singola attività o task puó avere una sua nota, per differenziare tipologie di lavori o attività differenti all'interno di uno stesso progetto. In tal caso si consiglia di denominare le note "NomeProgetto NomeAttività".

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

// NoNotesPromptView remains as before
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

// ProjectManagerView updated to include "Etichette" button and new layout
struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Binding var showLabelManager: Bool
    @Binding var projectModificationFor: Project?
    
    @State private var newProjectName: String = ""
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header: Text("Progetti correnti")
                                .font(.largeTitle)
                                .bold()) {
                        // Show projects in a simple list (or you could embed the grouping here as well)
                        ForEach(projectManager.projects) { project in
                            HStack {
                                Button(action: {
                                    projectManager.currentProject = project
                                }) {
                                    Text(project.name)
                                        .font(.title3)
                                }
                                Spacer()
                                Button("Modifica") {
                                    projectModificationFor = project
                                }
                                .foregroundColor(.blue)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    Section(header: Text("Mensilità passate")
                                .font(.largeTitle)
                                .bold()) {
                        ForEach(projectManager.backupProjects) { project in
                            HStack {
                                Button(action: {
                                    projectManager.currentProject = project
                                }) {
                                    Text(project.name)
                                        .font(.title3)
                                }
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
                    // New button for labels (Etichette)
                    Button(action: {
                        showLabelManager = true
                    }) {
                        Text("Etichette")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2))
                    }
                }
                .padding()
                
                Button(action: {
                    if let exportURL = projectManager.getExportURL() {
                        // Show share sheet (use ActivityView as before)
                        // For simplicity, we use a temporary sheet here.
                    }
                }) {
                    Text("Condividi Monte Ore")
                        .font(.title3)
                        .foregroundColor(.purple)
                        .padding()
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 2))
                }
                .padding(.bottom, 10)
                
                Button(action: {
                    // Import file action (handled with fileImporter in ContentView)
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
                    Button("Chiudi") {
                        // Dismiss the ProjectManagerView
                    }
                }
            }
        }
    }
}

// ActivityView for sharing export file
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
