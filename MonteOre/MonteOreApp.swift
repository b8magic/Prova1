

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Alert Structures
struct AlertError: Identifiable {
    var id: String { message }
    let message: String
}

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
                  red: Double(r)/255,
                  green: Double(g)/255,
                  blue: Double(b)/255,
                  opacity: Double(a)/255)
    }
}
extension UIColor {
    var toHex: String {
        var r: CGFloat=0, g: CGFloat=0, b: CGFloat=0, a: CGFloat=0
        getRed(&r, green:&g, blue:&b, alpha:&a)
        return String(format: "#%02X%02X%02X",
                      Int(r*255), Int(g*255), Int(b*255))
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
        id     = try c.decode(UUID.self,    forKey: .id)
        giorno = try c.decode(String.self,  forKey: .giorno)
        orari  = try c.decode(String.self,  forKey: .orari)
        note   = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
    var totalMinutes: Int {
        orari.split(separator: " ").reduce(0) { sum, seg in
            let parts = seg.split(separator: "-")
            guard parts.count == 2,
                  let s = minutes(from: String(parts[0])),
                  let e = minutes(from: String(parts[1])) else { return sum }
            return sum + max(0, e - s)
        }
    }
    var totalTimeString: String {
        let h = totalMinutes/60, m = totalMinutes%60
        return "\(h)h \(m)m"
    }
    private func minutes(from str: String) -> Int? {
        let p = str.split(separator: ":")
        guard p.count==2, let h=Int(p[0]), let m=Int(p[1]) else { return nil }
        return h*60+m
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

    init(name: String) { self.name=name; self.noteRows=[] }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        name     = try c.decode(String.self, forKey: .name)
        noteRows = try c.decode([NoteRow].self, forKey: .noteRows)
        labelID  = try? c.decode(UUID.self, forKey: .labelID)
    }
    func encode(to e: Encoder) throws {
        var c=e.container(keyedBy:CodingKeys.self)
        try c.encode(id, forKey:.id)
        try c.encode(name, forKey:.name)
        try c.encode(noteRows, forKey:.noteRows)
        try c.encode(labelID, forKey:.labelID)
    }
    var totalProjectMinutes: Int {
        noteRows.reduce(0){$0+$1.totalMinutes}
    }
    var totalProjectTimeString: String {
        let h=totalProjectMinutes/60, m=totalProjectMinutes%60
        return "\(h)h \(m)m"
    }
    func dateFromGiorno(_ s:String)->Date?{
        let fmt=DateFormatter()
        fmt.locale=Locale(identifier:"it_IT")
        fmt.dateFormat="EEEE dd/MM/yy"
        return fmt.date(from:s)
    }
}

// MARK: - ProjectManager
class ProjectManager: ObservableObject {
    @Published var projects:[Project]=[]
    @Published var backupProjects:[Project]=[]
    @Published var labels:[ProjectLabel]=[]
    @Published var currentProject:Project?{
        didSet{
            if let c=currentProject {
                UserDefaults.standard.set(c.id.uuidString,
                                          forKey:"lastProjectId")
            }
        }
    }
    @Published var lockedLabelID:UUID?{
        didSet{
            if let l=lockedLabelID {
                UserDefaults.standard.set(l.uuidString,
                                          forKey:"lockedLabelID")
            } else {
                UserDefaults.standard.removeObject(
                  forKey:"lockedLabelID")
            }
        }
    }

    private let projectsFileName="projects.json"
    private let backupOrderKey="backupOrder"

    init(){
        loadProjects()
        loadBackupProjects()
        loadLabels()
        if let s=UserDefaults.standard.string(
           forKey:"lockedLabelID"),
           let u=UUID(uuidString:s) {
            lockedLabelID=u
        }
        if let s=UserDefaults.standard.string(
           forKey:"lastProjectId"),
           let p=projects.first(where:{ $0.id.uuidString==s }) {
            currentProject=p
        } else {
            currentProject=projects.first
        }
        if projects.isEmpty {
            currentProject=nil
            saveProjects()
        }
    }

    // MARK: Projects
    func addProject(name:String){
        let p=Project(name:name)
        projects.append(p)
        currentProject=p
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(
          name:Notification.Name("CycleProjectNotification"),
          object:nil)
    }
    func renameProject(project:Project,newName:String){
        project.name=newName
        saveProjects()
        objectWillChange.send()
        NotificationCenter.default.post(
          name:Notification.Name("CycleProjectNotification"),
          object:nil)
    }
    func deleteProject(project:Project){
        if let i=projects.firstIndex(where:{ $0.id==project.id }){
            projects.remove(at:i)
            if currentProject?.id==project.id {
                currentProject=projects.first
            }
            saveProjects()
            objectWillChange.send()
            NotificationCenter.default.post(
              name:Notification.Name("CycleProjectNotification"),
              object:nil)
        }
    }

    // MARK: Persistence
    func getProjectsFileURL()->URL{
        FileManager.default.urls(
          for:.documentDirectory,in:.userDomainMask)[0]
        .appendingPathComponent(projectsFileName)
    }
    func saveProjects(){
        if let d=try? JSONEncoder().encode(projects){
            try? d.write(to:getProjectsFileURL())
        }
    }
    func loadProjects(){
        let u=getProjectsFileURL()
        if let d=try? Data(contentsOf:u),
           let arr=try? JSONDecoder().decode(
             [Project].self,from:d){
            projects=arr
        }
    }

    // MARK: Backup
    func getURLForBackup(project:Project)->URL{
        FileManager.default.urls(
          for:.documentDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("\(project.name).json")
    }
    func saveBackupProjects(){
        for p in backupProjects {
            let u=getURLForBackup(project:p)
            if let d=try? JSONEncoder().encode(p){
                try? d.write(to:u)
            }
        }
        saveBackupOrder()
    }
    func loadBackupProjects(){
        backupProjects=[]
        let docs=FileManager.default.urls(
          for:.documentDirectory,in:.userDomainMask)[0]
        if let files=try? FileManager.default.contentsOfDirectory(
           at:docs,includingPropertiesForKeys:nil) {
            for f in files {
                if f.lastPathComponent!=projectsFileName,
                   f.pathExtension=="json",
                   var p=try? JSONDecoder().decode(
                     Project.self,from:Data(contentsOf:f))
                {
                    p.id=UUID()
                    backupProjects.append(p)
                }
            }
        }
        let order=loadBackupOrder()
        var ord:[Project]=[]
        for id in order {
            if let p=backupProjects.first(where:{ $0.id==id }){
                ord.append(p)
            }
        }
        for p in backupProjects where !order.contains(p.id){
            ord.append(p)
        }
        backupProjects=ord
    }
    private func saveBackupOrder(){
        let arr=backupProjects.map{ $0.id.uuidString }
        UserDefaults.standard.set(arr,forKey:backupOrderKey)
    }
    private func loadBackupOrder()->[UUID]{
        guard let arr=UserDefaults.standard.stringArray(
           forKey:backupOrderKey) else { return [] }
        return arr.compactMap{ UUID(uuidString:$0) }
    }
    func deleteBackupProject(project:Project){
        let u=getURLForBackup(project:project)
        try? FileManager.default.removeItem(at:u)
        if let i=backupProjects.firstIndex(
           where:{ $0.id==project.id }){
            backupProjects.remove(at:i)
            saveBackupProjects()
        }
    }
    func isProjectRunning(_ project:Project)->Bool{
        project.noteRows.last?.orari.hasSuffix("-") ?? false
    }
    func backupCurrentProjectIfNeeded(
      _ project:Project,currentDate:Date,currentGiorno:String
    ){
        guard let last=project.noteRows.last,
              last.giorno!=currentGiorno,
              let d=project.dateFromGiorno(last.giorno)
        else { return }
        let cal=Calendar.current
        if cal.component(.month,from:d)
           != cal.component(.month,from:currentDate)
        {
            let fmt=DateFormatter()
            fmt.locale=Locale(identifier:"it_IT")
            fmt.dateFormat="LLLL"
            let m=fmt.string(from:d).capitalized
            let y=String(cal.component(.year,from:d)%100)
            let name="\(project.name) \(m) \(y)"
            let p=Project(name:name)
            p.noteRows=project.noteRows
            let u=getURLForBackup(project:p)
            if let d=try? JSONEncoder().encode(p){
                try? d.write(to:u)
            }
            loadBackupProjects()
            project.noteRows.removeAll()
            saveProjects()
        }
    }

    // MARK: Labels
    func addLabel(title:String,color:String){
        let l=ProjectLabel(title:title,color:color)
        labels.append(l)
        saveLabels(); objectWillChange.send()
        NotificationCenter.default.post(
          name:Notification.Name("CycleProjectNotification"),
          object:nil)
    }
    func renameLabel(label:ProjectLabel,newTitle:String){
        if let i=labels.firstIndex(
           where:{ $0.id==label.id }){
            labels[i].title=newTitle
            saveLabels(); objectWillChange.send()
            NotificationCenter.default.post(
              name:Notification.Name("CycleProjectNotification"),
              object:nil)
        }
    }
    func deleteLabel(label:ProjectLabel){
        labels.removeAll(where:{ $0.id==label.id })
        for p in projects   where p.labelID==label.id { p.labelID=nil }
        for p in backupProjects where p.labelID==label.id {
            p.labelID=nil
            let u=getURLForBackup(project:p)
            if let d=try? JSONEncoder().encode(p){
                try? d.write(to:u)
            }
        }
        saveLabels(); saveProjects(); saveBackupProjects()
        objectWillChange.send()
        if lockedLabelID==label.id {
            lockedLabelID=nil
            currentProject=projects.first
        }
        NotificationCenter.default.post(
          name:Notification.Name("CycleProjectNotification"),
          object:nil)
    }
    func saveLabels(){
        let u=FileManager.default.urls(
          for:.documentDirectory,in:.userDomainMask)[0]
          .appendingPathComponent("labels.json")
        if let d=try? JSONEncoder().encode(labels){
            try? d.write(to:u)
        }
    }
    func loadLabels(){
        let u=FileManager.default.urls(
          for:.documentDirectory,in:.userDomainMask)[0]
          .appendingPathComponent("labels.json")
        if let d=try? Data(contentsOf:u),
           let arr=try? JSONDecoder().decode(
             [ProjectLabel].self,from:d){
            labels=arr
        }
    }

    // MARK: Reordering
    func moveProjects(forLabel:UUID?,indices:IndexSet,newOffset:Int){
        var g=projects.filter{ $0.labelID==forLabel }
        g.move(fromOffsets:indices,toOffset:newOffset)
        projects.removeAll{ $0.labelID==forLabel }
        projects.append(contentsOf:g)
        saveProjects()
    }
    func moveBackupProjects(forLabel:UUID?,indices:IndexSet,newOffset:Int){
        var g=backupProjects.filter{ $0.labelID==forLabel }
        g.move(fromOffsets:indices,toOffset:newOffset)
        backupProjects.removeAll{ $0.labelID==forLabel }
        backupProjects.append(contentsOf:g)
        saveBackupProjects()
    }

    // MARK: Export
    struct ExportData:Codable {
        let projects:[Project]
        let backupProjects:[Project]
        let labels:[ProjectLabel]
        let lockedLabelID:String?
    }
    func getExportURL()->URL?{
        let d=ExportData(
          projects:projects,
          backupProjects:backupProjects,
          labels:labels,
          lockedLabelID:lockedLabelID?.uuidString
        )
        if let data=try? JSONEncoder().encode(d){
            let u=FileManager.default.temporaryDirectory
              .appendingPathComponent("MonteOreExport.json")
            try? data.write(to:u)
            return u
        }
        return nil
    }
    func getCSVExportURL()->URL?{
        let u=FileManager.default.temporaryDirectory
          .appendingPathComponent("MonteOreExport.txt")
        var txt=""
        for p in projects {
            txt += "\"\(p.name)\",\"\(p.totalProjectTimeString)\"\n"
            for r in p.noteRows {
                txt += "\(r.giorno),\"\(r.orari)\",\"\(r.totalTimeString)\",\"\(r.note)\"\n"
            }
            txt+="\n"
        }
        try? txt.write(to:u,atomically:true,encoding:.utf8)
        return u
    }
}

// MARK: - UI Components

struct ActivityView: UIViewControllerRepresentable {
    var activityItems:[Any]; var applicationActivities:[UIActivity]?=nil
    func makeUIViewController(
      context:Context)->UIActivityViewController
    {
        UIActivityViewController(
          activityItems:activityItems,
          applicationActivities:applicationActivities)
    }
    func updateUIViewController(
      _ vc:UIActivityViewController,
      context:Context){}
}

struct LabelAssignmentView:View{
    @ObservedObject var project:Project
    @ObservedObject var projectManager:ProjectManager
    @Environment(\.presentationMode) var pm
    @State private var closeVisible=false

    var body:some View{
        NavigationView{
            VStack{
                List{
                    ForEach(projectManager.labels){label in
                        HStack{
                            Circle()
                              .fill(Color(hex:label.color))
                              .frame(width:20,height:20)
                            Text(label.title)
                            Spacer()
                            if project.labelID==label.id{
                                Image(systemName:"checkmark.circle.fill")
                                  .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture{
                            withAnimation{
                                if project.labelID==label.id{
                                    project.labelID=nil
                                } else {
                                    project.labelID=label.id
                                    closeVisible=true
                                }
                            }
                            projectManager.saveProjects()
                            projectManager.objectWillChange.send()
                        }
                    }
                }
                if closeVisible {
                    Button(action: {
                        pm.wrappedValue.dismiss()
                    }) {
                        Text("Chiudi")
                            .frame(maxWidth:.infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Assegna Etichetta")
            .toolbar{
                ToolbarItem(placement:.cancellationAction){
                    Button("Annulla"){
                        pm.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

struct CombinedProjectEditSheet:View{
    @ObservedObject var project:Project
    @ObservedObject var projectManager:ProjectManager
    @Environment(\.presentationMode) var pm
    @State private var newName:String
    @State private var showDelete=false

    init(project:Project,projectManager:ProjectManager){
        self.project=project; self.projectManager=projectManager
        _newName=State(initialValue:project.name)
    }

    var body:some View{
        VStack(spacing:30){
            VStack{
                Text("Rinomina").font(.headline)
                TextField("Nuovo nome",text:$newName)
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .padding(.horizontal)
                Button(action:{
                    if projectManager.backupProjects.contains(where:{ $0.id==project.id }){
                        let old=project.name
                        project.name=newName
                        projectManager.deleteBackupProject(
                          project:Project(name:old))
                        projectManager.backupProjects.removeAll(
                          where:{ $0.name==old })
                        projectManager.backupProjects.append(project)
                        let u=projectManager.getURLForBackup(
                          project:project)
                        if let d=try?JSONEncoder().encode(project){
                            try?d.write(to:u)
                        }
                    } else {
                        projectManager.renameProject(
                          project:project,newName:newName)
                    }
                    pm.wrappedValue.dismiss()
                }){
                    Text("Conferma")
                      .frame(maxWidth:.infinity)
                      .padding()
                      .background(Color.green)
                      .foregroundColor(.white)
                      .cornerRadius(8)
                }
            }
            Divider()
            VStack{
                Text("Elimina").font(.headline)
                Button(action:{ showDelete=true }){
                    Text("Elimina")
                      .frame(maxWidth:.infinity)
                      .padding()
                      .background(Color.red)
                      .foregroundColor(.white)
                      .cornerRadius(8)
                }
                .alert(isPresented:$showDelete){
                    Alert(
                      title:Text("Elimina progetto"),
                      message:Text("Sei sicuro di voler eliminare \(project.name)?"),
                      primaryButton:.destructive(Text("Elimina")){
                          if projectManager.backupProjects.contains(where:{ $0.id==project.id }){
                              projectManager.deleteBackupProject(project:project)
                          } else {
                              projectManager.deleteProject(project:project)
                          }
                          pm.wrappedValue.dismiss()
                      },
                      secondaryButton:.cancel()
                    )
                }
            }
        }
        .padding()
    }
}

struct ProjectEditToggleButton:View{
    @Binding var isEditing:Bool
    var body: some View {
        Button(action:{ isEditing.toggle() }){
            Text(isEditing?"Fatto":"Modifica")
              .font(.headline)
              .padding(8)
              .foregroundColor(.blue)
        }
    }
}

struct ProjectRowView:View{
    @ObservedObject var project:Project
    @ObservedObject var projectManager:ProjectManager
    var editingProjects:Bool

    @State private var highlighted=false
    @State private var showSheet=false

    var body: some View {
        HStack(spacing:0){
            Button(action:{
                guard projectManager.lockedLabelID==nil
                      || project.labelID==projectManager.lockedLabelID
                else{return}
                withAnimation(.easeIn(duration:0.2)){highlighted=true}
                DispatchQueue.main.asyncAfter(deadline:.now()+0.2){
                    withAnimation(.easeOut(duration:0.2)){
                        highlighted=false
                    }
                    projectManager.currentProject=project
                }
            }){
                HStack{ Text(project.name).font(.title3); Spacer() }
                .padding(.vertical,8).padding(.horizontal,10)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(
                projectManager.lockedLabelID!=nil
                && project.labelID!=projectManager.lockedLabelID
            )
            Divider().frame(width:1).background(Color.gray)
            Button(action:{ showSheet=true }){
                Text(editingProjects?"Rinomina o Elimina":"Etichetta")
                  .font(.caption)
                  .padding(.horizontal,8)
                  .padding(.vertical,10)
                  .foregroundColor(.blue)
            }
        }
        .background(
            projectManager.isProjectRunning(project)
            ?Color.yellow
            : (highlighted?Color.gray.opacity(0.3):Color.clear)
        )
        .sheet(isPresented:$showSheet){
            if editingProjects {
                CombinedProjectEditSheet(
                  project:project,
                  projectManager:projectManager)
            } else {
                LabelAssignmentView(
                  project:project,
                  projectManager:projectManager)
            }
        }
        .onDrag{ NSItemProvider(
            object:project.id.uuidString as NSString) }
    }
}

struct LabelHeaderView:View{
    let label:ProjectLabel
    @ObservedObject var projectManager:ProjectManager
    var isBackup=false
    @State private var targeted=false

    var body: some View{
        HStack{
            Circle()
               .fill(Color(hex:label.color))
               .frame(width:16,height:16)
            Text(label.title)
               .font(.headline).underline()
               .foregroundColor(Color(hex:label.color))
            Spacer()
            Button(action:{
                if projectManager.lockedLabelID!=label.id {
                    projectManager.lockedLabelID=label.id
                    if let f=projectManager.projects.first(where:{
                       $0.labelID==label.id }){
                        projectManager.currentProject=f
                    }
                } else {
                    projectManager.lockedLabelID=nil
                    projectManager.currentProject = 
                      projectManager.projects.first
                }
            }){
                Image(systemName:
                      projectManager.lockedLabelID==label.id
                      ?"lock.fill":"lock.open")
                  .foregroundColor(.black)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical,8)
        .background(targeted?Color.blue.opacity(0.2):Color.clear)
        .onDrop(of:[UTType.text.identifier],
                isTargeted:$targeted){pro in
            pro.first?.loadItem(
              forTypeIdentifier:UTType.text.identifier,
              options:nil){data,_ in
                guard let d=data as? Data,
                      let s=String(data:d,encoding:.utf8),
                      let u=UUID(uuidString:s) else{return}
                DispatchQueue.main.async{
                    if isBackup {
                        if let i=projectManager.backupProjects.firstIndex(
                           where:{ $0.id==u }){
                            projectManager.backupProjects[i].labelID=label.id
                            projectManager.saveBackupProjects()
                        }
                    } else {
                        if let i=projectManager.projects.firstIndex(
                           where:{ $0.id==u }){
                            projectManager.projects[i].labelID=label.id
                            projectManager.saveProjects()
                        }
                    }
                }
            }
            return true
        }
    }
}

enum LabelActionType:Identifiable{
    case rename(label:ProjectLabel,initialText:String)
    case delete(label:ProjectLabel)
    case changeColor(label:ProjectLabel)
    var id:UUID{
        switch self {
        case .rename(let l,_),.delete(let l),.changeColor(let l):
            return l.id
        }
    }
}

struct LabelsManagerView:View{
    @ObservedObject var projectManager:ProjectManager
    @Environment(\.presentationMode) var pm
    @State private var newLabelTitle=""
    @State private var newLabelColor:Color = .black
    @State private var action:LabelActionType?=nil
    @State private var editing=false

    var body: some View{
        NavigationView{
            VStack{
                List{
                    ForEach(projectManager.labels){l in
                        HStack(spacing:12){
                            Button(action:{ action = .changeColor(label:l) }){
                                Circle()
                                  .fill(Color(hex:l.color))
                                  .frame(width:30,height:30)
                            }
                            .buttonStyle(PlainButtonStyle())
                            Text(l.title)
                            Spacer()
                            Button("Rinomina"){
                                action = .rename(label:l,initialText:l.title)
                            }
                            .foregroundColor(.blue)
                            .buttonStyle(BorderlessButtonStyle())
                            Button("Elimina"){
                                action = .delete(label:l)
                            }
                            .foregroundColor(.red)
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .onMove{idx,off in
                        projectManager.labels.move(
                          fromOffsets:idx,toOffset:off)
                        projectManager.saveLabels()
                    }
                }
                .listStyle(PlainListStyle())
                HStack{
                    TextField("Nuova etichetta",
                              text:$newLabelTitle)
                      .textFieldStyle(RoundedBorderTextFieldStyle())
                    ColorPicker("",selection:$newLabelColor,
                                supportsOpacity:false)
                      .labelsHidden()
                      .frame(width:50)
                    Button(action:{
                        guard!newLabelTitle.isEmpty else{return}
                        projectManager.addLabel(
                          title:newLabelTitle,
                          color:UIColor(newLabelColor).toHex)
                        newLabelTitle=""; newLabelColor = .black
                    }){
                        Text("Crea")
                          .frame(maxWidth:.infinity)
                          .padding()
                          .background(Color.green)
                          .foregroundColor(.white)
                          .cornerRadius(8)
                    }
                }
                .padding()
            }
            .navigationTitle("Etichette")
            .toolbar{
                ToolbarItem(placement:.cancellationAction){
                    Button("Chiudi"){ pm.wrappedValue.dismiss() }
                }
                ToolbarItem(placement:.primaryAction){
                    Button(editing?"Fatto":"Ordina"){
                        editing.toggle()
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                }
            }
            .environment(\.editMode,
              .constant(editing?.isEmpty==false ? .active : .inactive))
            .sheet(item:$action){act in
                switch act {
                case .rename(let l,let txt):
                    RenameLabelSheetWrapper(
                      projectManager:projectManager,
                      label:l,initialText:txt
                    ){action=nil}
                case .delete(let l):
                    DeleteLabelSheetWrapper(
                      projectManager:projectManager,
                      label:l
                    ){action=nil}
                case .changeColor(let l):
                    ChangeLabelColorDirectSheet(
                      projectManager:projectManager,
                      label:l
                    ){action=nil}
                }
            }
        }
    }
}

struct RenameLabelSheetWrapper:View{
    @ObservedObject var projectManager:ProjectManager
    @State var label:ProjectLabel
    @State var newName:String
    var onDismiss:()->Void

    init(projectManager:ProjectManager,
         label:ProjectLabel,
         initialText:String,
         onDismiss:@escaping()->Void)
    {
        self.projectManager=projectManager
        _label=State(initialValue:label)
        _newName=State(initialValue:initialText)
        self.onDismiss=onDismiss
    }

    var body:some View{
        VStack(spacing:20){
            Text("Rinomina Etichetta").font(.title)
            TextField("Nuovo nome",text:$newName)
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .padding()
            Button(action:{
                projectManager.renameLabel(
                  label:label,newTitle:newName)
                onDismiss()
            }){
                Text("Conferma")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.blue)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }
        }
        .padding()
    }
}

struct DeleteLabelSheetWrapper:View{
    @ObservedObject var projectManager:ProjectManager
    var label:ProjectLabel
    var onDismiss:()->Void

    var body:some View{
        VStack(spacing:20){
            Text("Elimina Etichetta").font(.title).bold()
            Text("Sei sicuro di voler eliminare \(label.title)?")
              .multilineTextAlignment(.center)
              .padding()
            Button(action:{
                projectManager.deleteLabel(label:label)
                onDismiss()
            }){
                Text("Elimina")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.red)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }
            Button(action:{onDismiss()}){
                Text("Annulla")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.gray)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }
        }.padding()
    }
}

struct ChangeLabelColorDirectSheet:View{
    @ObservedObject var projectManager:ProjectManager
    @State var label:ProjectLabel
    @State var selectedColor:Color
    var onDismiss:()->Void

    init(projectManager:ProjectManager,
         label:ProjectLabel,
         onDismiss:@escaping()->Void)
    {
        self.projectManager=projectManager
        _label=State(initialValue:label)
        _selectedColor=State(initialValue:Color(hex:label.color))
        self.onDismiss=onDismiss
    }

    var body:some View{
        VStack(spacing:20){
            Circle()
              .fill(selectedColor)
              .frame(width:150,height:150)
              .offset(y:-50)
            Text("Scegli un Colore").font(.title)
            ColorPicker("",selection:$selectedColor,
                        supportsOpacity:false)
              .labelsHidden().padding()
            Button(action:{
                if let i=projectManager.labels.firstIndex(where:{
                   $0.id==label.id }){
                    projectManager.labels[i].color = 
                      UIColor(selectedColor).toHex
                    projectManager.saveLabels()
                }
                onDismiss()
            }){
                Text("Conferma")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.green)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }
            Button(action:{onDismiss()}){
                Text("Annulla")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.red)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }
        }.padding()
    }
}

struct NoteView:View{
    @ObservedObject var project:Project
    var projectManager:ProjectManager
    @State private var editMode=false
    @State private var editedRows:[NoteRow]=[]

    private var nameColor:Color{
        if let lid=project.labelID,
           let hex=projectManager.labels.first(where:{
             $0.id==lid })?.color {
            return Color(hex:hex)
        }
        return .black
    }

    var body:some View{
        VStack(alignment:.leading,spacing:8){
            HStack(alignment:.top){
                VStack(alignment:.leading,spacing:4){
                    if let lid=project.labelID,
                       let lab=projectManager.labels.first(where:{
                         $0.id==lid })
                    {
                        HStack(spacing:8){
                            Text(lab.title)
                              .font(.headline).bold()
                            Circle()
                              .fill(Color(hex:lab.color))
                              .frame(width:24,height:24)
                              .overlay(Circle()
                                .stroke(Color.black,lineWidth:1))
                        }.foregroundColor(.black)
                    }
                    Text(project.name)
                      .font(.title3).bold()
                      .underline(true,color:nameColor)
                      .foregroundColor(.black)
                    Text("Tot Monte Ore: \(project.totalProjectTimeString)")
                      .font(.body).bold()
                }
                Spacer()
                if editMode{
                    VStack{
                        Button(action:{
                            var rows=editedRows.filter{
                                !($0.giorno.trimmingCharacters(
                                  in:.whitespaces).isEmpty &&
                                  $0.orari.trimmingCharacters(
                                  in:.whitespaces).isEmpty &&
                                  $0.note.trimmingCharacters(
                                  in:.whitespaces).isEmpty)
                            }
                            rows.sort{
                                guard let d1=project.dateFromGiorno(
                                  $0.giorno),
                                      let d2=project.dateFromGiorno(
                                      $1.giorno) else {
                                    return $0.giorno<$1.giorno
                                }
                                return d1<d2
                            }
                            project.noteRows=rows
                            projectManager.saveProjects()
                            editMode=false
                        }){
                            Text("Salva")
                              .frame(maxWidth:.infinity)
                              .padding()
                              .background(Color.green)
                              .foregroundColor(.white)
                              .cornerRadius(8)
                        }
                        Button("Annulla"){
                            editMode=false
                        }
                        .frame(maxWidth:.infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }.font(.body)
                } else {
                    Button("Modifica"){
                        editedRows=project.noteRows
                        editMode=true
                    }
                    .font(.body)
                    .foregroundColor(.blue)
                }
            }.padding(.bottom,5)

            if editMode{
                ScrollView{
                    VStack(spacing:8){
                        ForEach($editedRows){$row in
                            HStack(spacing:8){
                                TextField("Giorno",
                                          text:$row.giorno)
                                  .font(.system(size:14))
                                  .frame(height:60)
                                Divider().frame(height:60)
                                  .background(Color.black)
                                TextEditor(text:$row.orari)
                                  .font(.system(size:14))
                                  .frame(height:60)
                                Divider().frame(height:60)
                                  .background(Color.black)
                                Text(row.totalTimeString)
                                  .font(.system(size:14))
                                  .frame(height:60)
                                Divider().frame(height:60)
                                  .background(Color.black)
                                TextField("Note",
                                          text:$row.note)
                                  .font(.system(size:14))
                                  .frame(height:60)
                            }.padding(.vertical,4)
                        }
                    }.padding(.horizontal,8)
                }
            } else {
                ScrollView{
                    VStack(alignment:.leading,spacing:8){
                        ForEach(project.noteRows){row in
                            HStack(spacing:8){
                                Text(row.giorno)
                                  .font(.system(size:14))
                                  .frame(minHeight:60)
                                Divider().frame(height:60)
                                  .background(Color.black)
                                Text(row.orari)
                                  .font(.system(size:14))
                                  .frame(minHeight:60)
                                Divider().frame(height:60)
                                  .background(Color.black)
                                Text(row.totalTimeString)
                                  .font(.system(size:14))
                                  .frame(minHeight:60)
                                Divider().frame(height:60)
                                  .background(Color.black)
                                Text(row.note)
                                  .font(.system(size:14))
                                  .frame(minHeight:60)
                            }.padding(.vertical,2)
                        }
                    }.padding(.horizontal,8)
                }
            }
        }.padding(20)
    }
}

struct ComeFunzionaSheetView:View{
    var onDismiss:()->Void
    var body:some View{
        ScrollView{
            VStack(alignment:.leading,spacing:16){
                Group{
                    Text("Funzionalità generali").font(.headline)
                    Text("""
                    • Tieni premuto il bottone per avviare/fermare il tempo.\
                    • Salvataggio e archiviazione mensile automatica.
                    """)
                }
                Group{
                    Text("Etichette").font(.headline)
                    Text("""
                    • Usa etichette per raggruppare progetti.\
                    • Tieni premuto per ordinarle.
                    """)
                }
                Group{
                    Text("Progetti nascosti").font(.headline)
                    Text("""
                    • Backup mensili di sola lettura.
                    """)
                }
                Group{
                    Text("Buone pratiche e consigli").font(.headline)
                    Text("""
                    • Denomina progetti concisi.\
                    • Aggiungi ✅ nelle note una volta trasferite le ore.\
                    • Non includere mese/anno nel titolo.
                    """)
                }
            }.padding()
        }
        .background(Color.white).cornerRadius(12).padding()
        .overlay(
            Button(action:onDismiss){
                Text("Chiudi")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.green)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }.padding(.horizontal),
            alignment:.bottom
        )
    }
}

struct ProjectManagerView:View{
    @ObservedObject var projectManager:ProjectManager
    @State private var newProjectName=""
    @State private var showLabels=false
    @State private var showExportOpts=false
    @State private var exportURL:URL?=nil
    @State private var showActivity=false
    @State private var showImport=false
    @State private var importError:AlertError?=nil
    @State private var showHow=false
    @State private var showHowButton=false
    @State private var editMode:EditMode = .inactive
    @State private var editingProjects=false

    var body:some View{
        NavigationView{
            VStack{
                List{
                    Section(header:
                        Text("Progetti Correnti")
                          .font(.largeTitle).bold()
                          .padding(.top,10)
                    ){
                        let unl=projectManager.projects.filter{ $0.labelID==nil }
                        if !unl.isEmpty {
                            ForEach(unl){p in
                                ProjectRowView(
                                  project:p,
                                  projectManager:projectManager,
                                  editingProjects:editingProjects)
                            }
                            .onMove{idx,off in
                                projectManager.moveProjects(
                                  forLabel:nil,indices:idx,
                                  newOffset:off)
                            }
                        }
                        ForEach(projectManager.labels){lab in
                            LabelHeaderView(
                              label:lab,
                              projectManager:projectManager)
                            let grp=projectManager.projects.filter{
                                $0.labelID==lab.id }
                            if !grp.isEmpty {
                                ForEach(grp){p in
                                    ProjectRowView(
                                      project:p,
                                      projectManager:projectManager,
                                      editingProjects:editingProjects)
                                }
                                .onMove{idx,off in
                                    projectManager.moveProjects(
                                      forLabel:lab.id,
                                      indices:idx,
                                      newOffset:off)
                                }
                            }
                        }
                    }
                    Section(header:
                        Text("Mensilità Passate")
                          .font(.largeTitle).bold()
                          .padding(.top,40)
                    ){
                        let unl=projectManager.backupProjects.filter{
                            $0.labelID==nil }
                        if !unl.isEmpty {
                            ForEach(unl){p in
                                ProjectRowView(
                                  project:p,
                                  projectManager:projectManager,
                                  editingProjects:editingProjects)
                            }
                            .onMove{idx,off in
                                projectManager.moveBackupProjects(
                                  forLabel:nil,
                                  indices:idx,
                                  newOffset:off)
                            }
                        }
                        ForEach(projectManager.labels){lab in
                            let grp=projectManager.backupProjects.filter{
                                $0.labelID==lab.id }
                            if !grp.isEmpty {
                                LabelHeaderView(
                                  label:lab,
                                  projectManager:projectManager,
                                  isBackup:true)
                                ForEach(grp){p in
                                    ProjectRowView(
                                      project:p,
                                      projectManager:projectManager,
                                      editingProjects:editingProjects)
                                }
                                .onMove{idx,off in
                                    projectManager.moveBackupProjects(
                                      forLabel:lab.id,
                                      indices:idx,
                                      newOffset:off)
                                }
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .environment(\.editMode,$editMode)

                HStack{
                    TextField("Nuovo progetto",
                              text:$newProjectName)
                      .font(.title3)
                      .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action:{
                        guard!newProjectName.isEmpty else{return}
                        projectManager.addProject(
                          name:newProjectName)
                        newProjectName=""
                    }){
                        Text("Crea")
                          .frame(maxWidth:.infinity)
                          .padding()
                          .background(Color.green)
                          .foregroundColor(.white)
                          .cornerRadius(8)
                    }
                    Button(action:{ showLabels=true }){
                        Text("Etichette")
                          .frame(maxWidth:.infinity)
                          .padding()
                          .background(Color.red)
                          .foregroundColor(.white)
                          .cornerRadius(8)
                    }
                }.padding()

                HStack{
                    Button(action:{ showExportOpts=true }){
                        Text("Condividi Monte Ore")
                          .frame(maxWidth:.infinity)
                          .padding()
                          .background(Color.purple)
                          .foregroundColor(.white)
                          .cornerRadius(8)
                    }
                    Spacer()
                    Button(action:{ showImport=true }){
                        Text("Importa File")
                          .frame(maxWidth:.infinity)
                          .padding()
                          .background(Color.orange)
                          .foregroundColor(.white)
                          .cornerRadius(8)
                    }
                }.padding(.horizontal)
            }
            .navigationBarTitle("",displayMode:.inline)
            .toolbar{
                ToolbarItem(placement:.navigationBarLeading){
                    ProjectEditToggleButton(
                      isEditing:$editingProjects)
                }
                ToolbarItem(placement:.navigationBarTrailing){
                    if showHowButton {
                        Button("Come funziona l'app"){
                            showHow=true
                        }
                        .font(.custom("Permanent Marker",
                                      size:20))
                        .padding(8)
                        .background(Color.yellow)
                        .cornerRadius(8)
                    } else {
                        Button("?"){ showHowButton=true }
                          .font(.system(size:40))
                          .bold()
                          .foregroundColor(.yellow)
                    }
                }
            }
            .sheet(isPresented:$showLabels){
                LabelsManagerView(
                  projectManager:projectManager)
            }
            .confirmationDialog("Esporta Monte Ore",
                                isPresented:$showExportOpts,
                                titleVisibility:.visible){
                Button("Backup (JSON)"){
                    exportURL=projectManager.getExportURL()
                    showActivity=true
                }
                Button("Esporta CSV monte ore"){
                    exportURL=projectManager.getCSVExportURL()
                    showActivity=true
                }
                Button("Annulla",role:.cancel){}
            }
            .sheet(isPresented:$showActivity){
                if let u=exportURL {
                    ActivityView(activityItems:[u])
                }
            }
            .fileImporter(isPresented:$showImport,
                          allowedContentTypes:[.json]){res in
                switch res {
                case .success(let u):
                    guard u.startAccessingSecurityScopedResource()
                    else{return}
                    let d=try?Data(contentsOf:u)
                    u.stopAccessingSecurityScopedResource()
                    if let d=d,
                       let imp=try?JSONDecoder().decode(
                         ProjectManager.ExportData.self,from:d)
                    {
                        projectManager.projects=imp.projects
                        projectManager.backupProjects = 
                          imp.backupProjects.map{
                              var p=$0; p.id=UUID(); return p }
                        projectManager.labels=imp.labels
                        if let l=imp.lockedLabelID,
                           let uu=UUID(uuidString:l) {
                            projectManager.lockedLabelID=uu
                        } else {
                            projectManager.lockedLabelID=nil
                        }
                        projectManager.currentProject = 
                          projectManager.projects.first
                        projectManager.saveProjects()
                        projectManager.saveLabels()
                        projectManager.saveBackupProjects()
                    }
                default:break
                }
            }
            .alert(item:$importError){e in
                Alert(title:Text("Errore"),
                      message:Text(e.message),
                      dismissButton:.default(Text("OK")))
            }
            .sheet(isPresented:$showHow,
                   onDismiss:{showHowButton=false}){
                ComeFunzionaSheetView{showHow=false}
            }
            .onAppear{
                NotificationCenter.default.addObserver(
                  forName:Notification.Name("CycleProjectNotification"),
                  object:nil,queue:.main){_ in
                    cycleProject()
                }
            }
        }
    }

    private func cycleProject(){
        let cur=projectManager.currentProject
        if let cur=cur,
           projectManager.backupProjects.contains(where:{
             $0.id==cur.id })
        {
            let avail=projectManager.backupProjects
            guard let idx=avail.firstIndex(where:{
                  $0.id==cur.id }),avail.count>1
            else{return}
            projectManager.currentProject = 
              avail[(idx+1)%avail.count]
        } else {
            let avail:[Project]
            if let lid=projectManager.lockedLabelID {
                avail=projectManager.projects.filter{
                  $0.labelID==lid }
            } else {
                var list:[Project]=[]
                list+=projectManager.projects.filter{
                  $0.labelID==nil }
                for lab in projectManager.labels {
                    list+=projectManager.projects.filter{
                      $0.labelID==lab.id }
                }
                avail=list
            }
            guard let cur=projectManager.currentProject,
                  let idx=avail.firstIndex(where:{
                    $0.id==cur.id }),avail.count>1
            else{return}
            projectManager.currentProject = 
              avail[(idx+1)%avail.count]
        }
    }

    private func previousProject(){
        let cur=projectManager.currentProject
        if let cur=cur,
           projectManager.backupProjects.contains(where:{
             $0.id==cur.id })
        {
            let avail=projectManager.backupProjects
            guard let idx=avail.firstIndex(where:{
              $0.id==cur.id }),avail.count>1
            else{return}
            projectManager.currentProject = 
              avail[(idx-1+avail.count)%avail.count]
        } else {
            let avail:[Project]
            if let lid=projectManager.lockedLabelID {
                avail=projectManager.projects.filter{
                  $0.labelID==lid }
            } else {
                var list:[Project]=[]
                list+=projectManager.projects.filter{
                  $0.labelID==nil }
                for lab in projectManager.labels {
                    list+=projectManager.projects.filter{
                      $0.labelID==lab.id }
                }
                avail=list
            }
            guard let cur=projectManager.currentProject,
                  let idx=avail.firstIndex(where:{
                    $0.id==cur.id }),avail.count>1
            else{return}
            projectManager.currentProject = 
              avail[(idx-1+avail.count)%avail.count]
        }
    }

    private func mainButtonTapped(){
        guard let proj=projectManager.currentProject else { return }
        if projectManager.backupProjects.contains(where:{
           $0.id==proj.id }) { return }
        let now=Date()
        let df=DateFormatter();df.locale=Locale(identifier:"it_IT")
        df.dateFormat="EEEE dd/MM/yy"
        let giornoStr=df.string(from:now).capitalized
        let tf=DateFormatter();tf.locale=Locale(identifier:"it_IT")
        tf.dateFormat="HH:mm"
        let timeStr=tf.string(from:now)
        projectManager.backupCurrentProjectIfNeeded(
          proj,currentDate:now,currentGiorno:giornoStr)
        if proj.noteRows.isEmpty
           || proj.noteRows.last?.giorno!=giornoStr
        {
            proj.noteRows.append(
              NoteRow(giorno:giornoStr,orari:timeStr+"-",note:""))
        } else {
            var last=proj.noteRows.removeLast()
            if last.orari.hasSuffix("-") {
                last.orari+=timeStr
            } else {
                last.orari+=" "+timeStr+"-"
            }
            proj.noteRows.append(last)
        }
        projectManager.saveProjects()
    }
}

struct NoNotesPromptView:View{
    var onOk:()->Void
    var onNonCHoSbatti:()->Void
    var body:some View{
        VStack(spacing:20){
            Text("Nessun progetto attivo")
              .font(.title).bold()
            Text("Per iniziare, crea o seleziona un progetto.")
              .multilineTextAlignment(.center)
            HStack(spacing:20){
                Button(action:onOk){
                    Text("Crea/Seleziona Progetto")
                      .frame(maxWidth:.infinity)
                      .padding()
                      .background(Color.blue)
                      .foregroundColor(.white)
                      .cornerRadius(8)
                }
                Button(action:onNonCHoSbatti){
                    Text("Non CHo Sbatti")
                      .frame(maxWidth:.infinity)
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
        .shadow(radius:8)
    }
}

struct PopupView:View{
    let message:String
    var body:some View{
        Text(message)
          .font(.headline)
          .foregroundColor(.white)
          .padding()
          .background(Color.black.opacity(0.8))
          .cornerRadius(10)
          .shadow(radius:10)
    }
}

struct NonCHoSbattiSheetView:View{
    var onDismiss:()->Void
    var body:some View{
        VStack(spacing:20){
            Text("Frate, nemmeno io...")
              .font(.custom("Permanent Marker",size:28))
              .bold()
              .multilineTextAlignment(.center)
            Button(action:onDismiss){
                Text("Mh")
                  .frame(maxWidth:.infinity)
                  .padding()
                  .background(Color.green)
                  .foregroundColor(.white)
                  .cornerRadius(8)
            }
        }.padding(30)
    }
}

struct ContentView:View{
    @ObservedObject var projectManager=ProjectManager()
    @State private var showManager=false
    @State private var showNoSbatti=false
    @State private var showMedal=false
    @AppStorage("medalAwarded") private var medalAwarded=false

    var body:some View{
        GeometryReader{geo in
            let isLand=geo.size.width>geo.size.height
            let cur=projectManager.currentProject
            let isBackup=cur.map{ p in
                projectManager.backupProjects.contains(where:{ $0.id==p.id })
            } ?? false

            ZStack{
                Color(hex:"#54c0ff").edgesIgnoringSafeArea(.all)
                VStack(spacing:20){
                    if cur==nil{
                        NoNotesPromptView(
                          onOk:{showManager=true},
                          onNonCHoSbatti:{showNoSbatti=true})
                    } else if let proj=cur {
                        NoteView(
                          project:proj,
                          projectManager:projectManager)
                        .frame(
                          width:isLand ? geo.size.width : geo.size.width-40,
                          height:isLand ? geo.size.height*0.4 : geo.size.height*0.6
                        )
                        .background(
                          projectManager.isProjectRunning(proj)
                          ?Color.yellow
                          :Color.white.opacity(0.2)
                        )
                        .cornerRadius(25)
                        .clipped()
                    }

                    ZStack{
                        Button(action:{mainButtonTapped()}) {
                            Text("Pigia il tempo")
                              .font(.title2)
                              .foregroundColor(.white)
                              .frame(
                                width:isLand ? 100 : 140,
                                height:isLand ? 100 : 140)
                              .background(Circle().fill(Color.black))
                        }
                        .disabled(cur==nil||isBackup)

                        if isBackup {
                            Circle()
                              .fill(Color(hex:"#54c0ff"))
                              .frame(
                                width:isLand ? 100 : 140,
                                height:isLand ? 100 : 140)
                        }
                    }

                    HStack{
                        Button(action:{showManager=true}) {
                            Text("Gestione\nProgetti")
                              .font(.headline)
                              .multilineTextAlignment(.center)
                              .foregroundColor(.black)
                              .frame(
                                width:isLand?90:140,
                                height:isLand?100:140)
                              .background(Circle().fill(Color.white))
                              .overlay(Circle().stroke(Color.black,lineWidth:2))
                        }

                        Spacer()

                        ZStack{
                            Circle()
                              .fill(Color.yellow)
                              .frame(
                                width:isLand?90:140,
                                height:isLand?90:140)
                              .overlay(
                                Rectangle()
                                  .frame(
                                    width:(isLand?90:140),
                                    height:1),
                                alignment:.center
                              )
                            VStack(spacing:0){
                                Button(action:{previousProject()}) {
                                    Color.clear
                                }
                                .frame(height:(isLand?45:70))
                                Button(action:{cycleProject()}) {
                                    Color.clear
                                }
                                .frame(height:(isLand?45:70))
                            }
                            VStack{
                                Image(systemName:"chevron.up")
                                  .font(.title2)
                                  .padding(.top,16)
                                Spacer()
                                Image(systemName:"chevron.down")
                                  .font(.title2)
                                  .padding(.bottom,16)
                            }
                        }
                        .disabled(cur==nil)
                    }
                    .padding(.horizontal,isLand?10:30)
                    .padding(.bottom,isLand?0:30)
                }

                if showMedal {
                    PopupView(
                      message:"Congratulazioni! Hai guadagnato la medaglia \"Sbattimenti zero eh\"")
                    .transition(.scale)
                }
            }
            .sheet(isPresented:$showManager){
                ProjectManagerView(
                  projectManager:projectManager)
            }
            .sheet(isPresented:$showNoSbatti){
                NonCHoSbattiSheetView{
                    if !medalAwarded {
                        medalAwarded=true
                        showMedal=true
                        DispatchQueue.main.asyncAfter(
                          deadline:.now()+5){
                            withAnimation{showMedal=false}
                        }
                    }
                    showNoSbatti=false
                }
            }
        }
    }

    private func cycleProject(){
        let cur=projectManager.currentProject
        if let cur=cur,
           projectManager.backupProjects.contains(where:{ $0.id==cur.id })
        {
            let avail=projectManager.backupProjects
            guard let idx=avail.firstIndex(where:{ $0.id==cur.id }),
                  avail.count>1 else{return}
            projectManager.currentProject = 
              avail[(idx+1)%avail.count]
        } else {
            let avail:[Project]
            if let lid=projectManager.lockedLabelID {
                avail=projectManager.projects.filter{ $0.labelID==lid }
            } else {
                var list:[Project]=[]
                list+=projectManager.projects.filter{ $0.labelID==nil }
                for lab in projectManager.labels {
                    list+=projectManager.projects.filter{
                      $0.labelID==lab.id }
                }
                avail=list
            }
            guard let cur=projectManager.currentProject,
                  let idx=avail.firstIndex(where:{ $0.id==cur.id }),
                  avail.count>1 else{return}
            projectManager.currentProject = 
              avail[(idx+1)%avail.count]
        }
    }

    private func previousProject(){
        let cur=projectManager.currentProject
        if let cur=cur,
           projectManager.backupProjects.contains(where:{ $0.id==cur.id })
        {
            let avail=projectManager.backupProjects
            guard let idx=avail.firstIndex(where:{ $0.id==cur.id }),
                  avail.count>1 else{return}
            projectManager.currentProject = 
              avail[(idx-1+avail.count)%avail.count]
        } else {
            let avail:[Project]
            if let lid=projectManager.lockedLabelID {
                avail=projectManager.projects.filter{ $0.labelID==lid }
            } else {
                var list:[Project]=[]
                list+=projectManager.projects.filter{ $0.labelID==nil }
                for lab in projectManager.labels {
                    list+=projectManager.projects.filter{
                      $0.labelID==lab.id }
                }
                avail=list
            }
            guard let cur=projectManager.currentProject,
                  let idx=avail.firstIndex(where:{ $0.id==cur.id }),
                  avail.count>1 else{return}
            projectManager.currentProject = 
              avail[(idx-1+avail.count)%avail.count]
        }
    }

    private func mainButtonTapped(){
        guard let proj=projectManager.currentProject else{return}
        if projectManager.backupProjects.contains(where:{ $0.id==proj.id })
        {return}
        let now=Date()
        let df=DateFormatter();df.locale=Locale(identifier:"it_IT")
        df.dateFormat="EEEE dd/MM/yy"
        let giornoStr=df.string(from:now).capitalized
        let tf=DateFormatter();tf.locale=Locale(identifier:"it_IT")
        tf.dateFormat="HH:mm"
        let timeStr=tf.string(from:now)
        projectManager.backupCurrentProjectIfNeeded(
          proj,currentDate:now,currentGiorno:giornoStr)
        if proj.noteRows.isEmpty
           || proj.noteRows.last?.giorno!=giornoStr
        {
            proj.noteRows.append(
              NoteRow(giorno:giornoStr,
                      orari:timeStr+"-",note:""))
        } else {
            var last=proj.noteRows.removeLast()
            if last.orari.hasSuffix("-"){
                last.orari+=timeStr
            } else {
                last.orari+=" "+timeStr+"-"
            }
            proj.noteRows.append(last)
        }
        projectManager.saveProjects()
    }
}

// MARK: - App Entry
@main
struct MyTimeTrackerApp:App{
    var body: some Scene{
        WindowGroup{ ContentView() }
    }
}
