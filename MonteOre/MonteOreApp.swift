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
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// Estensione per convertire UIColor in Hex (usata per il ColorPicker)
extension UIColor {
    var toHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
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

// Nuova struttura per le etichette
struct ProjectLabel: Identifiable, Codable {
    var id = UUID()
    var title: String
    var color: String  // Es. "#FF0000"
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

class ProjectManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var backupProjects: [Project] = []
    @Published var labels: [ProjectLabel] = []
    
    @Published var currentProject: Project? {
        didSet { if let cp = currentProject { UserDefaults.standard.set(cp.id.uuidString, forKey: "lastProjectId") } }
    }
    
    // Stato del lucchetto: solo una etichetta può essere bloccata
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
    
    // Progetti
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
    
    // Backup
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
    
    // MARK: - Labels Management
    func addLabel(title: String, color: String) {
        let newLabel = ProjectLabel(title: title, color: color)
        labels.append(newLabel)
        saveLabels()
    }
    func renameLabel(label: ProjectLabel, newTitle: String) {
        if let index = labels.firstIndex(where: { $0.id == label.id }) {
            labels[index].title = newTitle
            saveLabels()
        }
    }
    func deleteLabel(label: ProjectLabel) {
        labels.removeAll(where: { $0.id == label.id })
        for proj in projects {
            if proj.labelID == label.id { proj.labelID = nil }
        }
        saveLabels()
        saveProjects()
        if lockedLabelID == label.id { lockedLabelID = nil }
    }
    func saveLabels() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let labelsURL = docs.appendingPathComponent("labels.json")
        do {
            let data = try JSONEncoder().encode(labels)
            try data.write(to: labelsURL)
        } catch {
            print("Error saving labels: \(error)")
        }
    }
    func loadLabels() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let labelsURL = docs.appendingPathComponent("labels.json")
        if let data = try? Data(contentsOf: labelsURL),
           let savedLabels = try? JSONDecoder().decode([ProjectLabel].self, from: data) {
            self.labels = savedLabels
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

// MARK: - NonCHoSbattiSheetView
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

// MARK: - ComeFunzionaSheetView
struct ComeFunzionaSheetView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack {
            Text("""
Se un'attività supera la mezzanotte, al momento di pigiarne il termine l'app creerà un nuovo giorno. Basterà modificare la nota col pulsante in alto a destra, e inserire un termine di fine orario che fuoriesca le 24. Ad esempio, se l'attività si è conclusa all'1:29, si inserisca 25:29.

Ogni singola attività o task può avere una sua nota, per differenziare tipologie di lavori o attività differenti all'interno di uno stesso progetto. In tal caso si consiglia di denominare le note "NomeProgetto NomeAttività".

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

// MARK: - LabelAssignmentView
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

// MARK: - LabelsManagerView
struct LabelsManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newLabelTitle: String = ""
    @State private var newLabelColor: Color = .black
    @State private var labelToRename: ProjectLabel? = nil
    @State private var renameText: String = ""
    @State private var showRenameAlert: Bool = false
    @State private var showDeleteAlert: Bool = false
    @State private var labelToDelete: ProjectLabel? = nil
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels) { label in
                        HStack {
                            Button(action: {
                                // Apre il ColorPicker in una sheet per cambiare il colore
                                labelToRename = label // usiamo la stessa variabile per il cambio colore
                            }) {
                                Circle()
                                    .fill(Color(hex: label.color))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(PlainButtonStyle())
                            Text(label.title)
                            Spacer()
                            Button("Rinomina") {
                                labelToRename = label
                                renameText = label.title
                                showRenameAlert = true
                            }
                            .foregroundColor(.blue)
                            Button("Elimina") {
                                labelToDelete = label
                                showDeleteAlert = true
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
                            let hex = UIColor(newLabelColor).toHex
                            projectManager.addLabel(title: newLabelTitle, color: hex)
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
            .alert(isPresented: $showRenameAlert) {
                Alert(
                    title: Text("Rinomina Etichetta"),
                    message: Text("Inserisci il nuovo nome per l'etichetta"),
                    primaryButton: .default(Text("OK"), action: {
                        if let label = labelToRename {
                            projectManager.renameLabel(label: label, newTitle: renameText)
                        }
                    }),
                    secondaryButton: .cancel()
                )
            }
            .alert(isPresented: $showDeleteAlert) {
                Alert(
                    title: Text("Elimina Etichetta"),
                    message: Text("Sei sicuro di voler eliminare l'etichetta \"\(labelToDelete?.title ?? "")\"?"),
                    primaryButton: .destructive(Text("Elimina"), action: {
                        if let label = labelToDelete {
                            projectManager.deleteLabel(label: label)
                        }
                    }),
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

// MARK: - ProjectRowView
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
            // Bottone "Modifica" semplice in blu
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
                    Text("Rinomina Progetto")
                        .font(.title)
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
            // Se è bloccata un'etichetta, solo i progetti appartenenti a quella vengono aperti
            if let locked = projectManager.lockedLabelID {
                if project.labelID == locked {
                    projectManager.currentProject = project
                }
            } else {
                projectManager.currentProject = project
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - LabelHeaderView
struct LabelHeaderView: View {
    let label: ProjectLabel
    @ObservedObject var projectManager: ProjectManager
    @State private var showLockInfo: Bool = false
    
    var body: some View {
        HStack {
            // Cerchietto colore
            Circle()
                .fill(Color(hex: label.color))
                .frame(width: 16, height: 16)
            Text(label.title)
                .font(.headline)
                .underline()
                .foregroundColor(Color(hex: label.color))
            Spacer()
            // Se non è bloccata nessuna o se questo è quella bloccata
            if projectManager.lockedLabelID == nil || projectManager.lockedLabelID == label.id {
                Button(action: {
                    // Se l'etichetta non è bloccata, blocca e mostra info
                    if projectManager.lockedLabelID != label.id {
                        projectManager.lockedLabelID = label.id
                        showLockInfo = true
                    } else {
                        // Sblocco senza tendina
                        projectManager.lockedLabelID = nil
                    }
                }) {
                    Image(systemName: projectManager.lockedLabelID == label.id ? "lock.fill" : "lock.open")
                        .foregroundColor(.black)
                }
                .buttonStyle(PlainButtonStyle())
                // Mostra popover solo quando l'etichetta viene bloccata
                .popover(isPresented: $showLockInfo, arrowEdge: .bottom) {
                    VStack(spacing: 20) {
                        Text("Il bottone Giallo è agganciato ai progetti dell'etichetta \"\(label.title)\"")
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
        .padding(.vertical, 4)
    }
}

// MARK: - ProjectManagerView (Gestione Progetti)
struct ProjectManagerView: View {
    @ObservedObject var projectManager: ProjectManager
    @State private var newProjectName: String = ""
    @State private var showEtichetteSheet: Bool = false
    // Stato per import/export
    @State private var showShareSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importError: AlertError? = nil
    @State private var pendingImportData: ExportData? = nil
    @State private var showImportConfirmationSheet: Bool = false
    // Stato per il pulsante "Come funziona l'app"
    @State private var showHowItWorks: Bool = false
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    // Sezione Progetti Correnti
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
                                LabelHeaderView(label: label, projectManager: projectManager)
                                ForEach(projectsForLabel) { project in
                                    ProjectRowView(project: project, projectManager: projectManager)
                                }
                            }
                        }
                    }
                    // Sezione Mensilità Passate
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
                                LabelHeaderView(label: label, projectManager: projectManager)
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
                    Button(action: {
                        showEtichetteSheet = true
                    }) {
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
            // Rimuoviamo il titolo della NavigationView per dare più spazio
            .navigationBarTitle("", displayMode: .inline)
            .toolbar {
                // Pulsante "?" giallo
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showHowItWorks = true }) {
                        Text("?")
                            .font(.system(size: 40))
                            .bold()
                            .foregroundColor(.yellow)
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
            .sheet(isPresented: $showHowItWorks) {
                // Mostra il bottone "Come funziona l'app" come da specifica
                VStack {
                    Button(action: { showHowItWorks = false }) {
                        Text("Come funziona l'app")
                            .font(.custom("Permanent Marker", size: 20))
                            .foregroundColor(.black)
                            .padding(8)
                            .background(Color.yellow)
                            .cornerRadius(8)
                    }
                }
            }
        }
    }
}

// MARK: - ActivityView
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
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
                    // Pulsante "Pigia il tempo" (sfondo nero)
                    Button(action: { mainButtonTapped() }) {
                        Text("Pigia il tempo")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: isLandscape ? 90 : 140, height: isLandscape ? 100 : 140)
                            .background(Circle().fill(Color.black))
                    }
                    .disabled(projectManager.currentProject == nil)
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
        let availableProjects: [Project]
        if let locked = projectManager.lockedLabelID {
            availableProjects = projectManager.projects.filter { $0.labelID == locked }
        } else {
            availableProjects = projectManager.projects
        }
        guard let current = projectManager.currentProject else { return }
        guard let currentIndex = availableProjects.firstIndex(where: { $0.id == current.id }),
              availableProjects.count > 1 else { return }
        let nextIndex = (currentIndex + 1) % availableProjects.count
        let nextProject = availableProjects[nextIndex]
        if projectManager.isProjectRunning(current) {
            let running = availableProjects.filter { projectManager.isProjectRunning($0) }
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
        // Implementa la riproduzione audio se desiderato
    }
}

// MARK: - NoteView
struct NoteView: View {
    @ObservedObject var project: Project
    var projectManager: ProjectManager
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

// MARK: - App Main
@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
