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
        case 3: (a, r, g, b) = (255, (int >> 8)*17, (int>>4&0xF)*17, (int&0xF)*17)
        case 6: (a, r, g, b) = (255, int>>16, int>>8&0xFF, int&0xFF)
        case 8: (a, r, g, b) = (int>>24, int>>16&0xFF, int>>8&0xFF, int&0xFF)
        default: (a, r, g, b) = (255, 0,0,0)
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
        var r: CGFloat=0,g: CGFloat=0,b: CGFloat=0,a: CGFloat=0
        getRed(&r, green:&g, blue:&b, alpha:&a)
        return String(format:"#%02X%02X%02X", Int(r*255),Int(g*255),Int(b*255))
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
        case .running(let newProject,_): return newProject.id.uuidString
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
    init(from decoder: Decoder)throws{
        let c=try decoder.container(keyedBy: CodingKeys.self)
        id=try c.decode(UUID.self, forKey:.id)
        giorno=try c.decode(String.self,forKey:.giorno)
        orari=try c.decode(String.self,forKey:.orari)
        note=(try? c.decode(String.self,forKey:.note)) ?? ""
    }
    init(giorno:String, orari:String, note:String=""){
        self.giorno=giorno; self.orari=orari; self.note=note
    }
    var totalMinutes: Int {
        let segments=orari.split(separator:" ")
        return segments.reduce(0){ total,seg in
            let parts=seg.split(separator:"-")
            if parts.count==2,
               let s=minutesFromString(String(parts[0])),
               let e=minutesFromString(String(parts[1])) {
                return total + max(0,e-s)
            }
            return total
        }
    }
    var totalTimeString: String {
        let h=totalMinutes/60, m=totalMinutes%60
        return "\(h)h \(m)m"
    }
    func minutesFromString(_ t:String)->Int?{
        let p=t.split(separator:":")
        if p.count==2, let hh=Int(p[0]), let mm=Int(p[1]) { return hh*60+mm }
        return nil
    }
}

struct ProjectLabel: Identifiable, Codable {
    var id=UUID()
    var title:String
    var color:String
}

class Project: Identifiable, ObservableObject, Codable {
    var id=UUID()
    @Published var name:String
    @Published var noteRows:[NoteRow]
    var labelID:UUID?=nil
    enum CodingKeys:CodingKey{ case id,name,noteRows,labelID }
    init(name:String){ self.name=name; self.noteRows=[] }
    required init(from decoder:Decoder)throws{
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self, forKey:.id)
        name=try c.decode(String.self,forKey:.name)
        noteRows=try c.decode([NoteRow].self,forKey:.noteRows)
        labelID=try? c.decode(UUID.self,forKey:.labelID)
    }
    func encode(to encoder:Encoder)throws{
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id)
        try c.encode(name,forKey:.name)
        try c.encode(noteRows,forKey:.noteRows)
        try c.encode(labelID,forKey:.labelID)
    }
    var totalProjectMinutes:Int { noteRows.reduce(0){$0+$1.totalMinutes} }
    var totalProjectTimeString:String {
        let h=totalProjectMinutes/60, m=totalProjectMinutes%60
        return "\(h)h \(m)m"
    }
    func dateFromGiorno(_ giorno:String)->Date? {
        let fmt=DateFormatter()
        fmt.locale = Locale(identifier:"it_IT")
        fmt.dateFormat = "EEEE dd/MM/yy"
        return fmt.date(from:giorno)
    }
    /// Remove empty rows & sort by date
    func cleanAndSortRows() {
        noteRows.removeAll { row in
            row.giorno.trimmingCharacters(in:.whitespaces).isEmpty &&
            row.orari.trimmingCharacters(in:.whitespaces).isEmpty &&
            row.note.trimmingCharacters(in:.whitespaces).isEmpty
        }
        noteRows.sort { a,b in
            guard let da=dateFromGiorno(a.giorno),
                  let db=dateFromGiorno(b.giorno)
            else { return true }
            return da<db
        }
    }
}

struct ExportData: Codable {
    let projects:[Project]
    let backupProjects:[Project]
    let labels:[ProjectLabel]
    let lockedLabelID:String?
}

// MARK: - ProjectManager

class ProjectManager: ObservableObject {
    @Published var projects:[Project]=[]
    @Published var backupProjects:[Project]=[]
    @Published var labels:[ProjectLabel]=[]
    @Published var currentProject:Project? {
        didSet { if let p=currentProject {
            UserDefaults.standard.set(p.id.uuidString,forKey:"lastProjectId")
        } }
    }
    @Published var lockedLabelID:UUID? {
        didSet {
            if let id=lockedLabelID {
                UserDefaults.standard.set(id.uuidString,forKey:"lockedLabelID")
            } else { UserDefaults.standard.removeObject(forKey:"lockedLabelID") }
        }
    }

    private let projectsFileName="projects.json"

    init(){
        loadProjects()
        loadBackupProjects()
        loadLabels()
        if let locked=UserDefaults.standard.string(forKey:"lockedLabelID"),
           let uuid=UUID(uuidString:locked) { lockedLabelID=uuid }
        if let last=UserDefaults.standard.string(forKey:"lastProjectId"),
           let p=projects.first(where:{ $0.id.uuidString==last }) {
            currentProject=p
        } else { currentProject=projects.first }
        if projects.isEmpty { currentProject=nil; saveProjects() }
    }

    // MARK: - Projects

    func addProject(name:String){
        let p=Project(name:name)
        projects.append(p)
        currentProject=p
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
    }
    func renameProject(project:Project,newName:String){
        project.name=newName
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
    }
    func deleteProject(project:Project){
        if let idx=projects.firstIndex(where:{ $0.id==project.id }){
            projects.remove(at:idx)
            if currentProject?.id==project.id { currentProject=projects.first }
            saveProjects()
            objectWillChange.send()
            NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
        }
    }

    // MARK: - Backup Handling

    func getURLForBackup(project:Project)->URL {
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        return docs.appendingPathComponent("\(project.name).json")
    }
    func backupCurrentProjectIfNeeded(_ project:Project, currentDate:Date, currentGiorno:String){
        guard let last=project.noteRows.last,
              last.giorno!=currentGiorno,
              let lastDate=project.dateFromGiorno(last.giorno)
        else{ return }
        let cal=Calendar.current
        if cal.component(.month,from:lastDate)!=cal.component(.month,from:currentDate){
            let fmt=DateFormatter(); fmt.locale=Locale(identifier:"it_IT"); fmt.dateFormat="LLLL"
            let monthName=fmt.string(from:lastDate).capitalized
            let yearSuffix=String(cal.component(.year,from:lastDate)%100)
            let backupName="\(project.name) \(monthName) \(yearSuffix)"
            let b=Project(name:backupName)
            b.noteRows=project.noteRows
            let url=getURLForBackup(project:b)
            if let data=try? JSONEncoder().encode(b) {
                try? data.write(to:url)
            }
            loadBackupProjects()
            project.noteRows.removeAll()
            saveProjects()
        }
    }
    func loadProjects(){
        let url=getURLForBackup(project:Project(name:projectsFileName)).deletingLastPathComponent().appendingPathComponent(projectsFileName)
        if let d=try? Data(contentsOf:url),
           let arr=try? JSONDecoder().decode([Project].self,from:d) {
            projects=arr
        }
    }
    func saveProjects(){
        let url=getURLForBackup(project:Project(name:projectsFileName)).deletingLastPathComponent().appendingPathComponent(projectsFileName)
        if let data=try? JSONEncoder().encode(projects) {
            try? data.write(to:url)
        }
    }
    func loadBackupProjects(){
        backupProjects=[]
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        if let files=try? FileManager.default.contentsOfDirectory(at:docs,includingPropertiesForKeys:nil){
            for file in files where file.pathExtension=="json" && file.lastPathComponent!=projectsFileName {
                if let d=try? Data(contentsOf:file),
                   let p=try? JSONDecoder().decode(Project.self,from:d){
                    backupProjects.append(p)
                }
            }
        }
    }
    func deleteBackupProject(project:Project){
        let url=getURLForBackup(project:project)
        try? FileManager.default.removeItem(at:url)
        if let idx=backupProjects.firstIndex(where:{ $0.id==project.id }){
            backupProjects.remove(at:idx)
        }
    }

    func isProjectRunning(_ p:Project)->Bool {
        p.noteRows.last?.orari.hasSuffix("-") == true
    }

    // MARK: - Labels

    func addLabel(title:String, color:String){
        labels.append(.init(title:title, color:color))
        saveLabels(); objectWillChange.send()
        NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
    }
    func renameLabel(label:ProjectLabel,newTitle:String){
        if let i=labels.firstIndex(where:{ $0.id==label.id }){
            labels[i].title=newTitle
            saveLabels(); objectWillChange.send()
            NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
        }
    }
    func deleteLabel(label:ProjectLabel){
        labels.removeAll{ $0.id==label.id }
        for p in projects where p.labelID==label.id { p.labelID=nil }
        for b in backupProjects where b.labelID==label.id { b.labelID=nil }
        saveLabels(); saveProjects(); objectWillChange.send()
        if lockedLabelID==label.id { lockedLabelID=nil }
        NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
    }
    func saveLabels(){
        let url=getURLForBackup(project:Project(name:"labels.json")).deletingLastPathComponent().appendingPathComponent("labels.json")
        if let data=try? JSONEncoder().encode(labels) {
            try? data.write(to:url)
        }
    }
    func loadLabels(){
        let url=getURLForBackup(project:Project(name:"labels.json")).deletingLastPathComponent().appendingPathComponent("labels.json")
        if let d=try? Data(contentsOf:url),
           let arr=try? JSONDecoder().decode([ProjectLabel].self,from:d){
            labels=arr
        }
    }

    // Reordering
    func moveProjects(forLabel:UUID?, indices:IndexSet, newOffset:Int){
        var group = projects.filter{ $0.labelID==forLabel }
        group.move(fromOffsets:indices,toOffset:newOffset)
        projects.removeAll{ $0.labelID==forLabel }
        projects.append(contentsOf:group)
    }
    func moveBackupProjects(forLabel:UUID?, indices:IndexSet, newOffset:Int){
        var group = backupProjects.filter{ $0.labelID==forLabel }
        group.move(fromOffsets:indices,toOffset:newOffset)
        backupProjects.removeAll{ $0.labelID==forLabel }
        backupProjects.append(contentsOf:group)
        // rewrite each backup file
        for b in backupProjects {
            let url = getURLForBackup(project:b)
            if let d=try? JSONEncoder().encode(b) {
                try? d.write(to:url)
            }
        }
    }

    // Export
    func getExportURL() -> URL? {
        let exportData=ExportData(projects:projects,
                                  backupProjects:backupProjects,
                                  labels:labels,
                                  lockedLabelID:lockedLabelID?.uuidString)
        if let d=try? JSONEncoder().encode(exportData) {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("MonteOreExport.json")
            try? d.write(to:url)
            return url
        }
        return nil
    }
    func getCSVExportURL() -> URL? {
        var lines:[String]=[]
        for p in projects {
            lines.append("\"\(p.name)\",\"\(p.totalProjectTimeString)\"")
            for r in p.noteRows {
                lines.append("\"\(r.giorno)\",\"\(r.orari)\",\"\(r.totalTimeString)\",\"\(r.note)\"")
            }
        }
        let txt = lines.joined(separator:"\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MonteOre.csv")
        try? txt.write(to:url,atomically:true,encoding:.utf8)
        return url
    }
}

// MARK: - Views

// MARK: ImportConfirmationView, ComeFunzionaSheetView

struct ImportConfirmationView: View {
    let message:String
    let importAction:() -> Void
    let cancelAction:() -> Void
    var body: some View {
        VStack(spacing:20) {
            Text("Importa File").font(.title).bold()
            Text(message).multilineTextAlignment(.center).padding()
            HStack {
                Button("Annulla"){ cancelAction() }
                    .font(.title2).foregroundColor(.red)
                    .padding().frame(maxWidth:.infinity)
                    .background(Color.white).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.red, lineWidth:2))
                Button("Importa"){ importAction() }
                    .font(.title2).foregroundColor(.white)
                    .padding().frame(maxWidth:.infinity)
                    .background(Color.yellow).cornerRadius(8)
            }
        }.padding()
    }
}

struct ComeFunzionaSheetView: View {
    let onDismiss:() -> Void
    var body: some View {
        ScrollView {
            VStack(alignment:.leading, spacing:20) {
                Text("Come funziona l'app").font(.largeTitle).bold()
                Group {
                    Text("• Funzionalità generali: crea progetti, registra tempi, visualizza totali.")
                    Text("• Etichette: raggruppano progetti, tieni premuto per ordinarle.")
                    Text("• Progetti nascosti: backup mensili accessibili in fondo.")
                }
                Divider()
                Text("Buone pratiche e consigli:")
                    .font(.headline)
                Text("• Usa emoji ✅ nella colonna note per segnare ore già trasferite.")
                Text("• Non includere mese/anno nel titolo, l'app li gestisce automaticamente.")
                Spacer().frame(height:20)
                Button("Chiudi"){ onDismiss() }
                    .font(.title2).foregroundColor(.white)
                    .padding().frame(maxWidth:.infinity)
                    .background(Color.green).cornerRadius(8)
            }.padding(30)
        }
    }
}

// MARK: LabelAssignmentView

struct LabelAssignmentView: View {
    @ObservedObject var project:Project
    @ObservedObject var projectManager:ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var closeButtonVisible=false

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels){ label in
                        HStack {
                            Circle().fill(Color(hex:label.color)).frame(width:20,height:20)
                            Text(label.title).font(.body)
                            Spacer()
                            if project.labelID==label.id {
                                Image(systemName:"checkmark.circle.fill").foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                if project.labelID==label.id {
                                    project.labelID=nil
                                } else {
                                    project.labelID=label.id
                                    closeButtonVisible=true
                                }
                            }
                            projectManager.saveProjects()
                        }
                    }
                }
                if closeButtonVisible {
                    Button("Chiudi"){ presentationMode.wrappedValue.dismiss() }
                        .font(.title2).foregroundColor(.white)
                        .padding().frame(maxWidth:.infinity)
                        .background(Color.green).cornerRadius(8)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Assegna Etichetta")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("Annulla"){ presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// MARK: ActivityView

struct ActivityView: UIViewControllerRepresentable {
    var activityItems:[Any]
    var applicationActivities:[UIActivity]?=nil
    func makeUIViewController(context:Context)->UIActivityViewController {
        UIActivityViewController(activityItems:activityItems,applicationActivities:applicationActivities)
    }
    func updateUIViewController(_ vc:UIActivityViewController, context:Context){}
}

// MARK: CombinedProjectEditSheet

struct CombinedProjectEditSheet: View {
    @ObservedObject var project:Project
    @ObservedObject var projectManager:ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newName:String

    @State private var showDeleteConfirmation=false

    init(project:Project, projectManager:ProjectManager){
        self.project=project; self.projectManager=projectManager
        _newName=State(initialValue:project.name)
    }
    var body: some View {
        VStack(spacing:30){
            // Rename
            VStack {
                Text("Rinomina").font(.headline)
                TextField("Nuovo nome", text:$newName)
                    .textFieldStyle(RoundedBorderTextFieldStyle()).padding(.horizontal)
                Button("Conferma"){ 
                    projectManager.renameProject(project:project,newName:newName)
                    presentationMode.wrappedValue.dismiss()
                }
                .font(.title2).foregroundColor(.white)
                .padding().frame(maxWidth:.infinity)
                .background(Color.green).cornerRadius(8)
            }
            Divider()
            // Delete
            VStack {
                Text("Elimina").font(.headline)
                Button("Elimina"){
                    showDeleteConfirmation=true
                }
                .font(.title2).foregroundColor(.white)
                .padding().frame(maxWidth:.infinity)
                .background(Color.red).cornerRadius(8)
                .alert(isPresented:$showDeleteConfirmation){
                    Alert(title:Text("Elimina progetto"),
                          message:Text("Sei sicuro di voler eliminare il progetto \(project.name)?"),
                          primaryButton:.destructive(Text("Elimina")){
                            projectManager.deleteProject(project:project)
                            presentationMode.wrappedValue.dismiss()
                          },
                          secondaryButton:.cancel())
                }
            }
        }.padding()
    }
}

// MARK: ProjectEditToggleButton

struct ProjectEditToggleButton: View {
    @Binding var isEditing:Bool
    var body: some View {
        Button(action:{isEditing.toggle()}){
            Text(isEditing ? "Fatto":"Modifica").font(.headline).padding(8)
                .foregroundColor(.blue)
        }
    }
}

// MARK: ProjectRowView

struct ProjectRowView: View {
    @ObservedObject var project:Project
    @ObservedObject var projectManager:ProjectManager
    var editingProjects:Bool
    @State private var isHighlighted=false
    @State private var showSecondarySheet=false

    var body: some View {
        HStack(spacing:0) {
            Button(action:{
                // locked-label guard (point 14)
                if let locked=projectManager.lockedLabelID,
                   project.labelID!=locked { return }
                withAnimation(.easeIn(duration:0.2)){ isHighlighted=true }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.2){
                    withAnimation(.easeOut(duration:0.2)){ isHighlighted=false }
                    projectManager.currentProject=project
                }
            }){
                HStack{
                    Text(project.name)
                        .font(.system(size:20)) // slightly bigger (pt.6)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.vertical,10)
                .padding(.horizontal,12)
            }
            .buttonStyle(PlainButtonStyle())
            Divider().frame(width:1).background(Color.gray)
            Button(action:{ showSecondarySheet=true }){
                Text(editingProjects ? "Rinomina o Elimina" : "Etichetta")
                    .font(.system(size:18)) // larger (pt.6)
                    .foregroundColor(.blue)
                    .padding(.horizontal,8)
                    .padding(.vertical,10)
            }
        }
        .background(projectManager.isProjectRunning(project) ? Color.yellow : (isHighlighted ? Color.gray.opacity(0.3) : Color.clear)) // yellow for running (pt.3)
        .sheet(isPresented:$showSecondarySheet){
            if editingProjects {
                CombinedProjectEditSheet(project:project, projectManager:projectManager)
            } else {
                LabelAssignmentView(project:project, projectManager:projectManager)
            }
        }
        .onDrag{ NSItemProvider(object:project.id.uuidString as NSString) }
    }
}

// MARK: SplitCircleButton (pt.11)

struct SplitCircleButton: View {
    var size:CGFloat
    var upAction:() -> Void
    var downAction:() -> Void

    var body: some View {
        ZStack {
            Circle().fill(Color.yellow).frame(width:size, height:size)
            GeometryReader { geo in
                let w=geo.size.width
                // top half
                Button(action:upAction) {
                    Color.clear
                }
                .frame(width:w, height:w/2)
                .position(x:w/2, y:w/4)
                // bottom half
                Button(action:downAction) {
                    Color.clear
                }
                .frame(width:w, height:w/2)
                .position(x:w/2, y:3*w/4)

                // arrows
                Image(systemName:"arrow.up")
                    .position(x:w/2, y:w*0.25)
                Image(systemName:"arrow.down")
                    .position(x:w/2, y:w*0.75)
            }
            .frame(width:size, height:size)
        }
    }
}

// MARK: Main & Bottom Buttons

struct MainButtonView: View {
    var isLandscape:Bool
    @ObservedObject var projectManager:ProjectManager

    var body: some View {
        Button(action:{ mainButtonTapped() }){
            Text("Pigia il tempo").font(.title2)
                .foregroundColor(.white)
                .frame(width: isLandscape ? 90:140, height: isLandscape ? 100:140)
                .background(Circle().fill(Color.black))
        }
        .disabled(projectManager.currentProject==nil ||
                  projectManager.backupProjects.contains{ $0.id==projectManager.currentProject?.id })
    }

    func mainButtonTapped(){
        guard let p=projectManager.currentProject else{ return }
        let now=Date()
        let df=DateFormatter(); df.locale=Locale(identifier:"it_IT"); df.dateFormat="EEEE dd/MM/yy"
        let giornoStr=df.string(from:now).capitalized
        let tf=DateFormatter(); tf.locale=Locale(identifier:"it_IT"); tf.dateFormat="HH:mm"
        let timeStr=tf.string(from:now)
        projectManager.backupCurrentProjectIfNeeded(p,currentDate:now,currentGiorno:giornoStr)
        if p.noteRows.isEmpty || p.noteRows.last?.giorno!=giornoStr {
            p.noteRows.append(NoteRow(giorno:giornoStr,orari:timeStr+"-",note:""))
        } else {
            var last=p.noteRows.removeLast()
            if last.orari.hasSuffix("-") { last.orari += timeStr }
            else { last.orari += " "+timeStr+"-" }
            p.noteRows.append(last)
        }
        projectManager.saveProjects()
    }
}

struct BottomButtonsView: View {
    var isLandscape:Bool
    @ObservedObject var projectManager:ProjectManager
    @Binding var showProjectManager:Bool

    var body: some View {
        HStack {
            Button("Gestione\nProgetti") {
                showProjectManager=true
            }
            .font(.headline).multilineTextAlignment(.center)
            .foregroundColor(.black)
            .frame(width:isLandscape?90:140,height:isLandscape?100:140)
            .background(Circle().fill(Color.white))
            .overlay(Circle().stroke(Color.black,lineWidth:2))
            .background(Color(hex:"#54c0ff"))

            Spacer()

            SplitCircleButton(size: isLandscape?90:140,
                              upAction: cycleBackward,
                              downAction: cycleForward) // split half (pt.11)
            .background(Color(hex:"#54c0ff"))
        }
        .padding(.horizontal,isLandscape?10:30)
        .padding(.bottom,isLandscape?0:30)
    }

    func cycleBackward(){
        cycle(offset:-1)
    }
    func cycleForward(){
        cycle(offset:1)
    }
    private func cycle(offset:Int){
        let available: [Project] = {
            if let locked=projectManager.lockedLabelID {
                return projectManager.projects.filter{ $0.labelID==locked }
            } else { return projectManager.projects }
        }()
        guard let current=projectManager.currentProject,
              let idx=available.firstIndex(where:{ $0.id==current.id }),
              available.count>1 else { return }
        let next = available[(idx+offset+available.count)%available.count]
        projectManager.currentProject=next
    }
}

// MARK: NoteView

struct NoteView: View {
    @ObservedObject var project:Project
    var projectManager:ProjectManager

    var body: some View {
        VStack {
            // pt.8: show etichetta above
            if let lid=project.labelID,
               let label=projectManager.labels.first(where:{ $0.id==lid }) {
                Text(label.title)
                    .font(.headline)
                    .foregroundColor(Color(hex:label.color))
            }
            HStack {
                Text(project.name)
                    .underline() // pt.2
                    .font(.title4) // slightly smaller (pt.6)
                    .foregroundColor(
                        project.labelID.flatMap{ id in
                            projectManager.labels.first{ $0.id==id }?.color
                        }.flatMap{ Color(hex:$0) } ?? .black
                    )
                Spacer()
                Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                    .font(.title4).bold() // smaller too
            }
            .padding(.bottom,5)
            ScrollView {
                VStack(alignment:.leading,spacing:8){
                    ForEach(project.noteRows){ row in
                        HStack {
                            Text(row.giorno).font(.system(size:15)) // smaller (pt.6)
                                .frame(minHeight:60)
                            Divider().frame(height:60).background(Color.black)
                            Text(row.orari).font(.system(size:15))
                                .frame(minHeight:60)
                            Divider().frame(height:60).background(Color.black)
                            Text(row.totalTimeString).font(.system(size:15))
                                .frame(minHeight:60)
                            Divider().frame(height:60).background(Color.black)
                            Text(row.note).font(.system(size:15))
                                .frame(minHeight:60)
                        }
                        .padding(.vertical,2)
                    }
                }
                .padding(.horizontal,8)
            }
        }
        .padding(20)
        .background(projectManager.isProjectRunning(project) ? Color.yellow : Color.clear) // pt.3
        .cornerRadius(25)
        .padding()
    }
}

// MARK: LabelHeaderView

struct LabelHeaderView: View {
    let label:ProjectLabel
    @ObservedObject var projectManager:ProjectManager
    var isBackup:Bool=false
    @State private var showLockInfo=false
    @State private var isTargeted=false

    var body: some View {
        HStack {
            Circle().fill(Color(hex:label.color)).frame(width:16,height:16)
            Text(label.title).font(.title2).underline()
                .foregroundColor(Color(hex:label.color)) // pt.6
            Spacer()
            if !isBackup && projectManager.projects.contains(where:{ $0.labelID==label.id }) {
                Button(action:{
                    if projectManager.lockedLabelID!=label.id {
                        projectManager.lockedLabelID=label.id
                        if let first=projectManager.projects.first(where:{ $0.labelID==label.id }){
                            projectManager.currentProject=first
                        }
                        showLockInfo=true
                    } else {
                        projectManager.lockedLabelID=nil
                    }
                }){
                    Image(systemName: projectManager.lockedLabelID==label.id ? "lock.fill" : "lock.open")
                        .foregroundColor(.black)
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented:$showLockInfo){
                    VStack(spacing:20){
                        Text("IL PULSANTE È AGGANCIO PER I PROGETTI DELL'ETICHETTA \(label.title)")
                            .font(.title).bold() // pt.2
                            .multilineTextAlignment(.center)
                        ForEach(projectManager.projects.filter{ $0.labelID==label.id }){ p in
                            Text(p.name)
                                .underline()
                                .font(.headline)
                                .foregroundColor(Color(hex:label.color))
                        }
                        Button("Chiudi"){ showLockInfo=false }
                            .foregroundColor(.white)
                            .padding().frame(maxWidth:.infinity)
                            .background(Color.green).cornerRadius(8)
                    }
                    .padding()
                    .frame(width:300)
                }
            } else {
                if projectManager.projects.filter({ $0.labelID==label.id }).isEmpty,
                   projectManager.lockedLabelID==label.id {
                    projectManager.lockedLabelID=nil
                }
            }
        }
        .padding(.vertical,8)
        .frame(minHeight:50)
        .background(isTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .onDrop(of:[UTType.text.identifier], isTargeted:$isTargeted){ providers in
            providers.first?.loadItem(forTypeIdentifier:UTType.text.identifier,options:nil){ data,err in
                if let d=data as? Data,
                   let s=String(data:d,encoding:.utf8),
                   let uuid=UUID(uuidString:s) {
                    DispatchQueue.main.async {
                        if !isBackup {
                            if let idx=projectManager.projects.firstIndex(where:{ $0.id==uuid }) {
                                projectManager.projects[idx].labelID=label.id
                                projectManager.saveProjects()
                            }
                        } else {
                            if let idx=projectManager.backupProjects.firstIndex(where:{ $0.id==uuid }) {
                                projectManager.backupProjects[idx].labelID=label.id
                                // save individual backup file (pt.15)
                                let url = projectManager.getURLForBackup(project: projectManager.backupProjects[idx])
                                if let d = try? JSONEncoder().encode(projectManager.backupProjects[idx]) {
                                    try? d.write(to: url)
                                }
                            }
                        }
                        projectManager.objectWillChange.send()
                        NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)
                    }
                }
            }
            return true
        }
    }
}

// MARK: LabelsManagerView

enum LabelActionType: Identifiable {
    case rename(label:ProjectLabel, initialText:String)
    case delete(label:ProjectLabel)
    case changeColor(label:ProjectLabel)
    var id:UUID {
        switch self {
        case .rename(let l,_), .delete(let l), .changeColor(let l): return l.id
        }
    }
}

struct LabelsManagerView: View {
    @ObservedObject var projectManager:ProjectManager
    @Environment(\.presentationMode) var presentationMode
    @State private var newLabelTitle:String=""
    @State private var newLabelColor:Color=.black
    @State private var activeLabelAction:LabelActionType?=nil
    @State private var isEditingLabels=false

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(projectManager.labels){ label in
                        HStack(spacing:12) {
                            Button(action:{ activeLabelAction = .changeColor(label:label) }){
                                Circle().fill(Color(hex:label.color))
                                    .frame(width:30,height:30)
                            }.buttonStyle(PlainButtonStyle())
                            Text(label.title)
                            Spacer()
                            Button("Rinomina"){ activeLabelAction = .rename(label:label, initialText:label.title) }
                                .buttonStyle(BorderlessButtonStyle()).foregroundColor(.blue)
                            Button("Elimina"){ activeLabelAction = .delete(label:label) }
                                .buttonStyle(BorderlessButtonStyle()).foregroundColor(.red)
                        }
                    }
                    .onMove{ idx,to in
                        projectManager.labels.move(fromOffsets:idx,toOffset:to)
                        projectManager.saveLabels()
                    }
                }
                HStack {
                    TextField("Nuova etichetta", text:$newLabelTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    ColorPicker("", selection:$newLabelColor, supportsOpacity:false)
                        .labelsHidden().frame(width:50)
                    Button("Crea") {
                        guard !newLabelTitle.isEmpty else{ return }
                        projectManager.addLabel(title:newLabelTitle, color:UIColor(newLabelColor).toHex)
                        newLabelTitle=""; newLabelColor=.black
                    }
                    .foregroundColor(.green).padding(8)
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.green,lineWidth:2))
                }.padding()
            }
            .navigationTitle("Etichette")
            .toolbar {
                ToolbarItem(placement:.cancellationAction){
                    Button("Chiudi"){ presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement:.primaryAction){
                    Button(isEditingLabels ? "Fatto":"Ordina"){
                        isEditingLabels.toggle()
                    }.font(.headline).foregroundColor(.blue)
                }
            }
            .environment(\.editMode, .constant(isEditingLabels ? .active : .inactive))
            .sheet(item:$activeLabelAction){ action in
                switch action {
                case .rename(let lbl, let txt):
                    RenameLabelSheetWrapper(projectManager:projectManager, label:lbl, initialText:txt){
                        activeLabelAction=nil
                    }
                case .delete(let lbl):
                    DeleteLabelSheetWrapper(projectManager:projectManager, label:lbl){
                        activeLabelAction=nil
                    }
                case .changeColor(let lbl):
                    ChangeLabelColorDirectSheet(projectManager:projectManager, label:lbl){
                        activeLabelAction=nil
                    }
                }
            }
        }
    }
}

// MARK: Rename/Delete/ChangeColor Wrappers

struct RenameLabelSheetWrapper: View {
    @ObservedObject var projectManager:ProjectManager
    @State var label:ProjectLabel
    @State var newName:String
    let onDismiss:() -> Void

    init(projectManager:ProjectManager, label:ProjectLabel, initialText:String, onDismiss:@escaping()->Void){
        self.projectManager=projectManager; _label=State(initialValue:label)
        _newName=State(initialValue:initialText); self.onDismiss=onDismiss
    }
    var body: some View {
        VStack(spacing:20){
            Text("Rinomina Etichetta").font(.title)
            TextField("Nuovo nome", text:$newName)
                .textFieldStyle(RoundedBorderTextFieldStyle()).padding()
            Button("Conferma"){
                projectManager.renameLabel(label:label,newTitle:newName)
                onDismiss()
            }
            .font(.title2).foregroundColor(.white)
            .padding().frame(maxWidth:.infinity)
            .background(Color.blue).cornerRadius(8)
        }.padding()
    }
}

struct DeleteLabelSheetWrapper: View {
    @ObservedObject var projectManager:ProjectManager
    var label:ProjectLabel
    let onDismiss:() -> Void

    var body: some View {
        VStack(spacing:20){
            Text("Elimina Etichetta").font(.title).bold()
            Text("Sei sicuro di voler eliminare l'etichetta \(label.title)?")
                .multilineTextAlignment(.center).padding()
            Button("Elimina"){
                projectManager.deleteLabel(label:label)
                onDismiss()
            }
            .font(.title2).foregroundColor(.white)
            .padding().frame(maxWidth:.infinity)
            .background(Color.red).cornerRadius(8)
            Button("Annulla"){ onDismiss() }
                .font(.title2).foregroundColor(.white)
                .padding().frame(maxWidth:.infinity)
                .background(Color.gray).cornerRadius(8)
        }.padding()
    }
}

struct ChangeLabelColorDirectSheet: View {
    @ObservedObject var projectManager:ProjectManager
    @State var label:ProjectLabel
    @State var selectedColor:Color
    let onDismiss:() -> Void

    init(projectManager:ProjectManager, label:ProjectLabel, onDismiss:@escaping()->Void){
        self.projectManager=projectManager; _label=State(initialValue:label)
        _selectedColor=State(initialValue:Color(hex:label.color))
        self.onDismiss=onDismiss
    }

    var body: some View {
        VStack(spacing:20){
            Circle()
                .fill(selectedColor)
                .frame(width:150,height:150)
                .padding(.top,55) // 1/3 higher (pt.1)
            Text("Scegli un Colore").font(.title)
            ColorPicker("", selection:$selectedColor, supportsOpacity:false)
                .labelsHidden().padding()
            Button("Conferma"){
                if let i=projectManager.labels.firstIndex(where:{ $0.id==label.id }){
                    projectManager.labels[i].color=UIColor(selectedColor).toHex
                    projectManager.saveLabels()
                }
                onDismiss() // also close (pt.1)
            }
            .font(.title2).foregroundColor(.white)
            .padding().frame(maxWidth:.infinity)
            .background(Color.green).cornerRadius(8)
            Button("Annulla"){ onDismiss() }
                .font(.title2).foregroundColor(.white)
                .padding().frame(maxWidth:.infinity)
                .background(Color.red).cornerRadius(8)
        }
        .padding()
    }
}

// MARK: ProjectManagerListView & ProjectManagerView

struct ProjectManagerListView: View {
    @ObservedObject var projectManager:ProjectManager
    var editingProjects:Bool

    var body: some View {
        List {
            Section(header:
                        Text("Progetti Correnti")
                            .font(.largeTitle).bold().padding(.top,10)
            ) {
                let unlabeled = projectManager.projects.filter{ $0.labelID==nil }
                if !unlabeled.isEmpty {
                    ForEach(unlabeled){ p in
                        ProjectRowView(project:p, projectManager:projectManager, editingProjects:editingProjects)
                    }
                    .onMove{ idx,to in
                        projectManager.moveProjects(forLabel:nil,indices:idx,newOffset:to)
                    }
                }
                ForEach(projectManager.labels){ label in
                    LabelHeaderView(label:label, projectManager:projectManager)
                    let ps = projectManager.projects.filter{ $0.labelID==label.id }
                    if !ps.isEmpty {
                        ForEach(ps){ p in
                            ProjectRowView(project:p, projectManager:projectManager, editingProjects:editingProjects)
                        }
                        .onMove{ idx,to in
                            projectManager.moveProjects(forLabel:label.id,indices:idx,newOffset:to)
                        }
                    }
                }
            }
            Section(header:
                        Text("Mensilità Passate")
                            .font(.largeTitle).bold().padding(.top,40)
            ) {
                let unlabeled = projectManager.backupProjects.filter{ $0.labelID==nil }
                if !unlabeled.isEmpty {
                    ForEach(unlabeled){ p in
                        ProjectRowView(project:p, projectManager:projectManager, editingProjects:editingProjects)
                    }
                    .onMove{ idx,to in
                        projectManager.moveBackupProjects(forLabel:nil,indices:idx,newOffset:to)
                    }
                }
                ForEach(projectManager.labels){ label in
                    let bu = projectManager.backupProjects.filter{ $0.labelID==label.id }
                    if !bu.isEmpty {
                        LabelHeaderView(label:label, projectManager:projectManager, isBackup:true)
                        ForEach(bu){ p in
                            ProjectRowView(project:p, projectManager:projectManager, editingProjects:editingProjects)
                        }
                        .onMove{ idx,to in
                            projectManager.moveBackupProjects(forLabel:label.id,indices:idx,newOffset:to)
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
}

struct ProjectManagerView: View {
    @ObservedObject var projectManager:ProjectManager
    @State private var newProjectName:String=""
    @State private var showEtichetteSheet=false
    @State private var showShareOptions=false // for export
    @State private var showImportSheet=false
    @State private var importError:AlertError?=nil
    @State private var pendingImportData:ExportData?=nil
    @State private var showImportConfirmationSheet=false
    @State private var showHowItWorksSheet=false
    @State private var showHowItWorksButton=false
    @State private var editMode:EditMode = .inactive
    @State private var editingProjects=false
    @State private var showExportActionSheet=false // pt.9

    var body: some View {
        NavigationView {
            VStack {
                ProjectManagerListView(projectManager:projectManager, editingProjects:editingProjects)
                HStack {
                    TextField("Nuovo progetto",text:$newProjectName)
                        .font(.title3).textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("Crea"){
                        guard !newProjectName.isEmpty else{ return }
                        projectManager.addProject(name:newProjectName)
                        newProjectName=""
                    }
                    .font(.title3).foregroundColor(.green)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.green,lineWidth:2))
                    Button("Etichette"){
                        showEtichetteSheet=true
                    }
                    .font(.title3).foregroundColor(.red)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.red,lineWidth:2))
                }.padding()
                HStack {
                    Button("Condividi Monte Ore"){
                        showExportActionSheet=true
                    }
                    .font(.title3).foregroundColor(.purple)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.purple,lineWidth:2))
                    Spacer()
                    Button("Importa File"){
                        showImportSheet=true
                    }
                    .font(.title3).foregroundColor(.orange)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.orange,lineWidth:2))
                }
                .padding(.horizontal)
            }
            .navigationBarTitle("",displayMode:.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading){
                    ProjectEditToggleButton(isEditing:$editingProjects)
                }
                ToolbarItem(placement:.navigationBarTrailing){
                    if showHowItWorksButton {
                        Button("Come funziona l'app"){
                            showHowItWorksSheet=true
                        }
                        .font(.custom("Permanent Marker",size:20))
                        .foregroundColor(.black)
                        .padding(8)
                        .background(Color.yellow)
                        .cornerRadius(8)
                    } else {
                        Button("?"){
                            showHowItWorksButton=true
                        }
                        .font(.system(size:40)).bold().foregroundColor(.yellow)
                    }
                }
            }
            // Etichette sheet
            .sheet(isPresented:$showEtichetteSheet){
                LabelsManagerView(projectManager:projectManager)
            }
            // Importer
            .fileImporter(isPresented:$showImportSheet,allowedContentTypes:[UTType.json]){ result in
                switch result {
                case .success(let url):
                    if url.startAccessingSecurityScopedResource() {
                        defer{ url.stopAccessingSecurityScopedResource() }
                        do {
                            let d=try Data(contentsOf:url)
                            let imp=try JSONDecoder().decode(ExportData.self,from:d)
                            pendingImportData=imp
                            showImportConfirmationSheet=true
                        } catch {
                            importError=AlertError(message:"Errore nell'importazione: \(error)")
                        }
                    } else {
                        importError=AlertError(message:"Impossibile accedere al file.")
                    }
                case .failure(let err):
                    importError=AlertError(message:"Errore: \(err.localizedDescription)")
                }
            }
            .alert(item:$importError){ e in
                Alert(title:Text("Errore"), message:Text(e.message), dismissButton:.default(Text("OK")))
            }
            .sheet(isPresented:$showImportConfirmationSheet){
                if let pending = pendingImportData {
                    ImportConfirmationView(
                        message: "Attenzione: sovrascrivere tutto?",
                        importAction: {
                            projectManager.projects=pending.projects
                            projectManager.backupProjects=pending.backupProjects
                            projectManager.labels=pending.labels
                            if let s=pending.lockedLabelID, let u=UUID(uuidString:s) {
                                projectManager.lockedLabelID=u
                            } else { projectManager.lockedLabelID=nil }
                            projectManager.currentProject=pending.projects.first
                            projectManager.saveProjects()
                            projectManager.saveLabels()
                            pendingImportData=nil
                            showImportConfirmationSheet=false
                        },
                        cancelAction:{
                            pendingImportData=nil
                            showImportConfirmationSheet=false
                        }
                    )
                } else {
                    Text("Errore: nessun dato da importare.")
                }
            }
            // How it works
            .sheet(isPresented:$showHowItWorksSheet, onDismiss:{
                showHowItWorksButton=false
            }){
                ComeFunzionaSheetView{ showHowItWorksSheet=false }
            }
            // Export action sheet (pt.9)
            .actionSheet(isPresented:$showExportActionSheet){
                ActionSheet(title:Text("Esporta Monte Ore"), buttons:[
                    .default(Text("Backup JSON")) {
                        if let url=projectManager.getExportURL() {
                            UIApplication.shared.windows.first?.rootViewController?
                                .present(UIActivityViewController(activityItems:[url],applicationActivities:nil), animated:true)
                        }
                    },
                    .default(Text("Esporta CSV monte ore")) {
                        if let url=projectManager.getCSVExportURL() {
                            UIApplication.shared.windows.first?.rootViewController?
                                .present(UIActivityViewController(activityItems:[url],applicationActivities:nil), animated:true)
                        }
                    },
                    .cancel()
                ])
            }
            .onAppear{
                NotificationCenter.default.addObserver(forName:.init("CycleProjectNotification"),object:nil,queue:.main){ _ in
                    cycleProject()
                }
            }
        }
    }

    @State private var switchAlert:ActiveAlert? = nil

    func cycleProject(){
        let available: [Project] = {
            if let locked=projectManager.lockedLabelID {
                return projectManager.projects.filter{ $0.labelID==locked }
            } else { return projectManager.projects }
        }()
        guard let current=projectManager.currentProject,
              let idx=available.firstIndex(where:{ $0.id==current.id }),
              available.count>1 else { return }
        let next = available[(idx+1)%available.count]
        projectManager.currentProject=next
    }
}

// MARK: - NoNotesPromptView, PopupView, NonCHoSbattiSheetView

struct NoNotesPromptView: View {
    var onOk:() -> Void
    var onNonCHoSbatti:() -> Void
    var body: some View {
        VStack(spacing:20){
            Text("Nessun progetto attivo").font(.title).bold()
            Text("Per iniziare, crea o seleziona un progetto.")
                .multilineTextAlignment(.center)
            HStack(spacing:20){
                Button("Crea/Seleziona Progetto"){ onOk() }
                    .padding().background(Color.blue).foregroundColor(.white).cornerRadius(8)
                Button("Non CHo Sbatti"){ onNonCHoSbatti() }
                    .padding().background(Color.orange).foregroundColor(.white).cornerRadius(8)
            }
        }
        .padding().background(Color.white).cornerRadius(12).shadow(radius:8)
    }
}

struct PopupView: View {
    let message:String
    var body: some View {
        Text(message).font(.headline).foregroundColor(.white)
            .padding().background(Color.black.opacity(0.8))
            .cornerRadius(10).shadow(radius:10)
    }
}

struct NonCHoSbattiSheetView: View {
    let onDismiss:() -> Void
    var body: some View {
        VStack(spacing:20){
            Text("Frate, nemmeno io...").font(.custom("Permanent Marker",size:28))
                .bold().foregroundColor(.black).multilineTextAlignment(.center)
            Button("Mh"){ onDismiss() }
                .font(.title2).foregroundColor(.white)
                .padding().frame(maxWidth:.infinity)
                .background(Color.green).cornerRadius(8)
        }
        .padding(30)
    }
}

// MARK: ContentView & App

struct ContentView: View {
    @ObservedObject var projectManager = ProjectManager()
    @State private var showProjectManager=false
    @State private var showNonCHoSbattiSheet=false
    @State private var showPopup=false
    @AppStorage("medalAwarded") private var medalAwarded:Bool=false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let showPrompt = projectManager.currentProject == nil
            ZStack {
                Color(hex:"#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing:20){
                    if showPrompt {
                        NoNotesPromptView(onOk:{ showProjectManager=true },
                                          onNonCHoSbatti:{ showNonCHoSbattiSheet=true })
                    } else if let project = projectManager.currentProject {
                        NoteView(project:project, projectManager:projectManager)
                    }
                    MainButtonView(isLandscape:isLandscape, projectManager:projectManager)
                    BottomButtonsView(isLandscape:isLandscape, projectManager:projectManager, showProjectManager:$showProjectManager)
                }
                if showPopup {
                    PopupView(message:"Congratulazioni! Hai guadagnato la medaglia Sbattimenti zero eh")
                        .transition(.scale)
                }
            }
            .sheet(isPresented:$showProjectManager){
                ProjectManagerView(projectManager:projectManager)
            }
            .sheet(isPresented:$showNonCHoSbattiSheet){
                NonCHoSbattiSheetView {
                    if !medalAwarded {
                        medalAwarded=true; showPopup=true
                        DispatchQueue.main.asyncAfter(deadline:.now()+5){
                            withAnimation{ showPopup=false }
                        }
                    }
                    showNonCHoSbattiSheet=false
                }
            }
        }
    }
}

@main
struct MyTimeTrackerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
