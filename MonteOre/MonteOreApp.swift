import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Color Extensions
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int>>8)*17, (int>>4&0xF)*17, (int&0xF)*17)
        case 6: (a, r, g, b) = (255, int>>16, int>>8&0xFF, int&0xFF)
        case 8: (a, r, g, b) = (int>>24, int>>16&0xFF, int>>8&0xFF, int&0xFF)
        default: (a, r, g, b) = (255,0,0,0)
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
        getRed(&r,green:&g,blue:&b,alpha:&a)
        return String(format:"#%02X%02X%02X",Int(r*255),Int(g*255),Int(b*255))
    }
}

// MARK: - Alert Types
struct AlertError: Identifiable { let message:String; var id:String{message} }
enum ActiveAlert: Identifiable {
    case running(newProject:Project)
    var id:String{switch self{case .running(let p): return p.id.uuidString}}
}

// MARK: - Models
struct NoteRow:Identifiable,Codable{var id=UUID(),giorno:String,orari:String,note:String=""
  var totalMinutes:Int{orari.split(separator:" ").reduce(0){sum,seg in
    let parts=seg.split(separator:"-");guard parts.count==2,
      let s=minutesFromString(String(parts[0])),
      let e=minutesFromString(String(parts[1])) else{return sum}
    return sum + max(0,e-s)
  }}
  var totalTimeString:String{ let h=totalMinutes/60, m=totalMinutes%60; return "\(h)h \(m)m" }
  func minutesFromString(_ t:String)->Int?{let p=t.split(separator:":")
    guard p.count==2,let h=Int(p[0]),let m=Int(p[1]) else{return nil}
    return h*60+m}
  init(giorno:String,orari:String,note:String=""){(self.giorno,self.orari,self.note)=(giorno,orari,note)}
  init(from d:Decoder)throws{let c=try d.container(keyedBy:CodingKeys.self)
    id=try c.decode(UUID.self,forKey:.id)
    giorno=try c.decode(String.self,forKey:.giorno)
    orari=try c.decode(String.self,forKey:.orari)
    note=(try?c.decode(String.self,forKey:.note)) ?? "" }
  enum CodingKeys:String,CodingKey{case id,giorno,orari,note}
}
struct ProjectLabel:Identifiable,Codable{var id=UUID(),title:String,color:String}

class Project:Identifiable,ObservableObject,Codable {
  var id=UUID()
  @Published var name:String
  @Published var noteRows:[NoteRow]
  var labelID:UUID?=nil
  enum CodingKeys:CodingKey{case id,name,noteRows,labelID}
  init(name:String){self.name=name;noteRows=[]}
  required init(from d:Decoder)throws{let c=try d.container(keyedBy:CodingKeys.self)
    id=try c.decode(UUID.self,forKey:.id)
    name=try c.decode(String.self,forKey:.name)
    noteRows=try c.decode([NoteRow].self,forKey:.noteRows)
    labelID=try?c.decode(UUID.self,forKey:.labelID) }
  func encode(to e:Encoder)throws{var c=e.container(keyedBy:CodingKeys.self)
    try c.encode(id,forKey:.id); try c.encode(name,forKey:.name)
    try c.encode(noteRows,forKey:.noteRows); try c.encode(labelID,forKey:.labelID)}
  var totalProjectMinutes:Int{noteRows.reduce(0){$0+$1.totalMinutes}}
  var totalProjectTimeString:String{let h=totalProjectMinutes/60,m=totalProjectMinutes%60;return "\(h)h \(m)m"}
  func dateFromGiorno(_ g:String)->Date?{let f=DateFormatter();f.locale=Locale(identifier:"it_IT");f.dateFormat="EEEE dd/MM/yy";return f.date(from:g)}
}

// MARK: - Manager
class ProjectManager:ObservableObject{
  @Published var projects=[Project](),backupProjects=[Project](),labels=[ProjectLabel]()
  @Published var currentProject:Project?{didSet{if let c=currentProject{UserDefaults.standard.set(c.id.uuidString,forKey:"lastProjectId")}}}
  @Published var lockedLabelID:UUID?{didSet{
    if let l=lockedLabelID{UserDefaults.standard.set(l.uuidString,forKey:"lockedLabelID")}
    else{UserDefaults.standard.removeObject(forKey:"lockedLabelID")}}}
  private let fileName="projects.json"
  init(){
    load();loadBackup();loadLabels()
    if let s=UserDefaults.standard.string(forKey:"lockedLabelID"),let u=UUID(uuidString:s){lockedLabelID=u}
    if let s=UserDefaults.standard.string(forKey:"lastProjectId"),let p=projects.first(where:{ $0.id.uuidString==s }){currentProject=p}
    else{currentProject=projects.first}
    if projects.isEmpty{currentProject=nil;save()}
  }
  func addProject(name:String){let p=Project(name:name);projects.append(p);currentProject=p;save();objectWillChange.send();notify()}
  func renameProject(_ p:Project,newName:String){p.name=newName;save();objectWillChange.send();notify()}
  func deleteProject(_ p:Project){if let i=projects.firstIndex(where:{ $0.id==p.id }){projects.remove(at:i);if currentProject?.id==p.id{currentProject=projects.first};save();objectWillChange.send();notify()}}
  func isProjectRunning(_ p:Project)->Bool{ p.noteRows.last?.orari.hasSuffix("-")==true }
  private func docs()->URL{return FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]}
  private func path()->URL{return docs().appendingPathComponent(fileName)}
  func save(){do{let d=try JSONEncoder().encode(projects);try d.write(to:path())}catch{print(error)}}
  func load(){if let d=try?Data(contentsOf:path()),let a=try?JSONDecoder().decode([Project].self,from:d){projects=a}}
  
  // Backup
  func getBackupURL(for p:Project)->URL{return docs().appendingPathComponent("\(p.name).json")}
  func backupIfNeeded(_ p:Project){let now=Date(),f=DateFormatter();f.locale=Locale(identifier:"it_IT");f.dateFormat="EEEE dd/MM/yy";let gs=f.string(from:now)
    if let lr=p.noteRows.last,lr.giorno!=gs,let ld=p.dateFromGiorno(lr.giorno){
      let cal=Calendar.current
      if cal.component(.month,from:ld)!=cal.component(.month,from:now){
        let mf=DateFormatter();mf.locale=Locale(identifier:"it_IT");mf.dateFormat="LLLL";let mn=mf.string(from:ld).capitalized;let yy=String(cal.component(.year,from:ld)%100)
        let bp=Project(name:"\(p.name) \(mn) \(yy)");bp.noteRows=p.noteRows;let url=getBackupURL(for:bp);if let d=try?JSONEncoder().encode(bp){
          do{try d.write(to:url);print("Backup to \(url)")}catch{print(error)}
        };loadBackup();p.noteRows.removeAll();save()
      }
    }
  }
  func loadBackup(){backupProjects=[];for url in (try?docs().contentsOfDirectory()) ?? []{
      if url.pathExtension=="json"&&url.lastPathComponent!=fileName {
        if let d=try?Data(contentsOf:url),let p=try?JSONDecoder().decode(Project.self,from:d){backupProjects.append(p)}
      }
    }
  }
  
  // Labels
  func addLabel(title:String,color:String){labels.append(ProjectLabel(title:title,color:color));saveLabels();objectWillChange.send();notify()}
  func renameLabel(_ l:ProjectLabel,newTitle:String){if let i=labels.firstIndex(where:{ $0.id==l.id }){labels[i].title=newTitle;saveLabels();objectWillChange.send();notify()}}
  func deleteLabel(_ l:ProjectLabel){
    labels.removeAll{ $0.id==l.id }
    for p in projects{if p.labelID==l.id{p.labelID=nil}}
    for p in backupProjects{if p.labelID==l.id{p.labelID=nil}}
    saveLabels();save();objectWillChange.send()
    if lockedLabelID==l.id{lockedLabelID=nil}
    notify()
  }
  func saveLabels(){let url=docs().appendingPathComponent("labels.json");do{let d=try JSONEncoder().encode(labels);try d.write(to:url)}catch{print(error)}}
  func loadLabels(){let url=docs().appendingPathComponent("labels.json");if let d=try?Data(contentsOf:url),let a=try?JSONDecoder().decode([ProjectLabel].self,from:d){labels=a}}
  
  // Reordering
  func moveProjects(for labelID:UUID?, from:IndexSet, to:Int){
    var grp=projects.filter{ $0.labelID==labelID }
    grp.move(fromOffsets:from,toOffset:to)
    projects.removeAll{ $0.labelID==labelID }
    projects.append(contentsOf:grp)
  }
  
  private func notify(){NotificationCenter.default.post(name:.init("CycleProjectNotification"),object:nil)}
}

// MARK: - ExportData
struct ExportData:Codable{
  let projects:[Project],backupProjects:[Project],labels:[ProjectLabel],lockedLabelID:String?
}
extension ProjectManager{
  func exportURL()->URL?{
    let ed=ExportData(projects:projects,backupProjects:backupProjects,labels:labels,lockedLabelID:lockedLabelID?.uuidString)
    if let d=try?JSONEncoder().encode(ed){
      let u=FileManager.default.temporaryDirectory.appendingPathComponent("MonteOreExport.json")
      try?d.write(to:u);return u
    }
    return nil
  }
}

// MARK: - Views

// 1) Label Assignment
struct LabelAssignmentView:View{
  @ObservedObject var project:Project
  @ObservedObject var pm:ProjectManager
  @Environment(\.presentationMode)var pmode
  @State private var closeVisible=false
  var body: some View{
    NavigationView{
      VStack{
        List(pm.labels){l in
          HStack{
            Circle().fill(Color(hex:l.color)).frame(width:20,height:20)
            Text(l.title).font(.headline)
            Spacer()
            if project.labelID==l.id{
              Image(systemName:"checkmark.circle.fill").foregroundColor(.blue)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture{
            if project.labelID==l.id{ project.labelID=nil }
            else{ project.labelID=l.id; closeVisible=true }
            pm.save();pm.objectWillChange.send()
          }
        }
        if closeVisible{
          Button("Chiudi"){
            pmode.wrappedValue.dismiss()
          }
          .font(.title2).foregroundColor(.white)
          .padding().frame(maxWidth:.infinity)
          .background(Color.green).cornerRadius(8)
          .padding(.horizontal)
        }
      }
      .navigationTitle("Assegna Etichetta")
      .toolbar{
        ToolbarItem(placement:.cancellationAction){Button("Annulla"){pmode.dismiss()}}
      }
    }
  }
}

// 2) Combined Rename/Delete for Project
struct CombinedProjectEditSheet:View{
  @ObservedObject var project:Project
  @ObservedObject var pm:ProjectManager
  @Environment(\.presentationMode)var md
  @State private var newName:String
  @State private var showDeleteConfirm=false
  init(project:Project,pm:ProjectManager){
    self.project=project;self.pm=pm;_newName=State(initialValue:project.name)
  }
  var body: some View{
    VStack(spacing:30){
      VStack{
        Text("Rinomina").font(.headline)
        TextField("Nuovo nome",text:$newName).textFieldStyle(RoundedBorderTextFieldStyle()).padding(.horizontal)
        Button("Conferma"){pm.renameProject(project,newName:newName);md.dismiss()}
          .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.green).cornerRadius(8)
      }
      Divider()
      VStack{
        Text("Elimina").font(.headline)
        Button("Elimina"){showDeleteConfirm=true}
          .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.red).cornerRadius(8)
          .alert("Elimina progetto",isPresented:$showDeleteConfirm){
            Button("Elimina",role:.destructive){pm.deleteProject(project);md.dismiss()}
            Button("Annulla",role:.cancel){}
          } message:{Text("Sei sicuro di voler eliminare \(project.name)?")}
      }
    }.padding()
  }
}

// 3) Toggle Edit for Projects
struct ProjectEditToggleButton:View{
  @Binding var editing:Bool
  var body: some View{
    Button(editing ? "Fatto" : "Modifica"){editing.toggle()}
      .font(.headline).foregroundColor(.blue).padding(8)
  }
}

// 4) Project Row
struct ProjectRowView:View{
  @ObservedObject var project:Project
  @ObservedObject var pm:ProjectManager
  var editing:Bool
  @State private var highlighted=false
  @State private var showSheet=false
  var body: some View{
    HStack(spacing:0){
      Button{
        highlighted=true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){highlighted=false;pm.currentProject=project}
      }label:{
        HStack{
          Text(project.name).font(.system(size:18,weight:.medium))
          Spacer()
        }.padding(.vertical,8).padding(.horizontal,10)
      }.buttonStyle(PlainButtonStyle())
      Divider().frame(width:1).background(Color.gray)
      Button(action:{showSheet=true}){
        Text(editing ? "Rinomina o Elimina" : "Etichetta")
          .font(.system(size:18)).foregroundColor(.blue)
          .padding(.horizontal,8).padding(.vertical,10)
      }
    }
    .background(
      project.noteRows.last?.orari.hasSuffix("-")==true ? Color.yellow :
      highlighted ? Color.gray.opacity(0.3) : Color.clear
    )
    .sheet(isPresented:$showSheet){
      if editing { CombinedProjectEditSheet(project:project,pm:pm) }
      else{ LabelAssignmentView(project:project,pm:pm) }
    }
    .onDrag{NSItemProvider(object:project.id.uuidString as NSString)}
  }
}

// 5) Label Header with Drag & Drop + Lock logic
struct LabelHeaderView:View{
  let label:ProjectLabel
  @ObservedObject var pm:ProjectManager
  var isBackup:Bool=false
  @State private var showLock=false, targeted=false
  var body: some View{
    HStack{
      Circle().fill(Color(hex:label.color)).frame(width:16,height:16)
      Text(label.title).font(.headline).underline().foregroundColor(Color(hex:label.color))
      Spacer()
      if !isBackup && pm.projects.contains(where:{ $0.labelID==label.id }){
        Button{ // unlock if empty
          if pm.lockedLabelID==label.id{ pm.lockedLabelID=nil }
          else{ pm.lockedLabelID=label.id }
          showLock=true
        }label:{
          Image(systemName:pm.lockedLabelID==label.id ? "lock.fill":"lock.open")
            .foregroundColor(.black)
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented:$showLock){
          VStack(spacing:20){
            Text(label.title).font(.title).bold()
              .underline().foregroundColor(Color(hex:label.color))
            Text("Il pulsante è agganciato ai progetti di questa etichetta")
              .font(.title3).bold().multilineTextAlignment(.center)
            Button("Chiudi"){showLock=false}
              .foregroundColor(.white).padding().frame(maxWidth:.infinity)
              .background(Color.green).cornerRadius(8)
          }.padding().frame(width:300)
        }
      }
    }
    .padding(.vertical,8)
    .background(targeted ? Color.blue.opacity(0.2) : Color.clear)
    .onAppear{
      // unlock empty labels automatically
      if !pm.projects.contains(where:{ $0.labelID==label.id }) && pm.lockedLabelID==label.id {
        pm.lockedLabelID=nil
      }
    }
    .onDrop(of:[UTType.text.identifier],isTargeted:$targeted){providers in
      providers.first?.loadItem(forTypeIdentifier:UTType.text.identifier){
        data,_ in if let d=data as? Data,let id=String(data:d,encoding:.utf8),let uu=UUID(uuidString:id){
          DispatchQueue.main.async{
            if let i=pm.projects.firstIndex(where:{ $0.id==uu }){
              pm.projects[i].labelID=label.id;pm.save();pm.objectWillChange.send();pm.notify()
            }
          }
        }
      }
      return true
    }
  }
}

// 6) Labels Manager
enum LabelAction:Identifiable{
  case rename(ProjectLabel,String), delete(ProjectLabel), color(ProjectLabel)
  var id:UUID{
    switch self{
      case .rename(let l,_): return l.id
      case .delete(let l): return l.id
      case .color(let l): return l.id
    }
  }
}
struct LabelsManagerView:View{
  @ObservedObject var pm:ProjectManager
  @Environment(\.presentationMode)var md
  @State private var newTitle="", newColor:Color=.black
  @State private var action:LabelAction?=nil
  @State private var editing=false
  var body: some View{
    NavigationView{
      VStack{
        List{
          ForEach(pm.labels){l in
            HStack(spacing:12){
              Button{action=.color(l)}label:{
                Circle().fill(Color(hex:l.color)).frame(width:30,height:30)
              }.buttonStyle(PlainButtonStyle())
              Text(l.title).font(.body)
              Spacer()
              Button("Rinomina"){action=.rename(l,l.title)}
                .foregroundColor(.blue).buttonStyle(BorderlessButtonStyle())
              Button("Elimina"){action=.delete(l)}
                .foregroundColor(.red).buttonStyle(BorderlessButtonStyle())
            }.contentShape(Rectangle())
          }
          .onMove{pm.labels.move(fromOffsets:$0,toOffset:$1);pm.saveLabels()}
        }
        .listStyle(PlainListStyle())
        HStack{
          TextField("Nuova etichetta",text:$newTitle).textFieldStyle(RoundedBorderTextFieldStyle())
          ColorPicker("",selection:$newColor,supportsOpacity:false).labelsHidden().frame(width:50)
          Button("Crea"){
            guard !newTitle.isEmpty else{return}
            pm.addLabel(title:newTitle,color:UIColor(newColor).toHex)
            newTitle="";newColor=.black
          }.foregroundColor(.green).padding(8)
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.green,lineWidth:2))
        }.padding()
      }
      .navigationTitle("Etichette")
      .toolbar{
        ToolbarItem(placement:.cancellationAction){Button("Chiudi"){md.dismiss()}}
        ToolbarItem(placement:.primaryAction){Button(editing ? "Fatto":"Ordina"){editing.toggle()}}
      }
      .environment(\.editMode, .constant(editing ? EditMode.active:EditMode.inactive))
      .sheet(item:$action){act in
        switch act {
        case .rename(let l,let t): RenameLabelWrapper(pm:pm,label:l,initial:t){action=nil}
        case .delete(let l): DeleteLabelWrapper(pm:pm,label:l){action=nil}
        case .color(let l): ChangeColorWrapper(pm:pm,label:l){action=nil}
        }
      }
    }
  }
}

// Label wrappers
struct RenameLabelWrapper:View{
  @ObservedObject var pm:ProjectManager
  @State var label:ProjectLabel
  @State var name:String
  var done:()->Void
  init(pm:ProjectManager,label:ProjectLabel,initial:String,done:@escaping()->Void){
    self.pm=pm;self._label=State(initialValue:label);self._name=State(initialValue:initial);self.done=done
  }
  var body: some View{
    VStack(spacing:20){
      Text("Rinomina Etichetta").font(.title)
      TextField("Nuovo nome",text:$name).textFieldStyle(RoundedBorderTextFieldStyle()).padding()
      Button("Conferma"){pm.renameLabel(label,newTitle:name);done()}
        .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.blue).cornerRadius(8)
    }.padding()
  }
}
struct DeleteLabelWrapper:View{
  @ObservedObject var pm:ProjectManager
  var label:ProjectLabel;var done:()->Void
  var body: some View{
    VStack(spacing:20){
      Text("Elimina Etichetta").font(.title).bold()
      Text("Sei sicuro di voler eliminare \(label.title)?").multilineTextAlignment(.center).padding()
      Button("Elimina"){pm.deleteLabel(label);done()}
        .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.red).cornerRadius(8)
      Button("Annulla"){done()}
        .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.gray).cornerRadius(8)
    }.padding()
  }
}
struct ChangeColorWrapper:View{
  @ObservedObject var pm:ProjectManager
  @State var label:ProjectLabel
  @State var sel:Color
  var done:()->Void
  init(pm:ProjectManager,label:ProjectLabel,done:@escaping()->Void){
    self.pm=pm;self._label=State(initialValue:label);self._sel=State(initialValue:Color(hex:label.color));self.done=done
  }
  var body: some View{
    VStack(spacing:20){
      Circle().fill(sel).frame(width:150,height:150)
      Text("Scegli un Colore").font(.title)
      ColorPicker("",selection:$sel,supportsOpacity:false).labelsHidden().padding()
      Button("Conferma"){
        if let i=pm.labels.firstIndex(where:{ $0.id==label.id }){
          pm.labels[i].color=UIColor(sel).toHex;pm.saveLabels()
        }
        done()
      }
      .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.green).cornerRadius(8)
      Button("Annulla"){done()}
        .foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.red).cornerRadius(8)
    }.padding()
  }
}

// Main Project Manager
struct ProjectManagerView:View{
  @ObservedObject var pm:ProjectManager
  @State private var newName="", showLabels=false, showShare=false, showImport=false
  @State private var err:AlertError?, pending:ExportData?, showImportConfirm=false
  @State private var showHow=false,howBtn=false, editMode:EditMode=.inactive, editing=false
  var body: some View{
    NavigationView{
      VStack{
        List{
          Section(header:Text("Progetti Correnti").font(.largeTitle).bold().padding(.top,10)){
            let unl=pm.projects.filter{ $0.labelID==nil }
            if !unl.isEmpty {
              ForEach(unl){p in ProjectRowView(project:p,pm:pm,editing:editing)}
                .onMove{pm.moveProjects(for:nil,from:$0,to:$1)}
            }
            ForEach(pm.labels){l in
              LabelHeaderView(label:l,pm:pm)
              let grp=pm.projects.filter{ $0.labelID==l.id }
              if !grp.isEmpty{
                ForEach(grp){p in ProjectRowView(project:p,pm:pm,editing:editing)}
                .onMove{pm.moveProjects(for:l.id,from:$0,to:$1)}
              }
            }
          }
          Section(header:Text("Mensilità Passate").font(.largeTitle).bold().padding(.top,40)){
            let unl=pm.backupProjects.filter{ $0.labelID==nil }
            if !unl.isEmpty{ForEach(unl){p in ProjectRowView(project:p,pm:pm,editing:editing)}
              .onMove{pm.moveProjects(for:nil,from:$0,to:$1)}
            }
            ForEach(pm.labels){l in
              LabelHeaderView(label:l,pm:pm,isBackup:true)
              let grp=pm.backupProjects.filter{ $0.labelID==l.id }
              if !grp.isEmpty{
                ForEach(grp){p in ProjectRowView(project:p,pm:pm,editing:editing)}
                  .onMove{pm.moveProjects(for:l.id,from:$0,to:$1)}
              }
            }
          }
        }.listStyle(PlainListStyle()).environment(\.editMode,$editMode)
        HStack{
          TextField("Nuovo progetto",text:$newName).font(.title3).textFieldStyle(RoundedBorderTextFieldStyle())
          Button("Crea"){if !newName.isEmpty{pm.addProject(name:newName);newName=""}}
            .foregroundColor(.green).padding(8).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.green,lineWidth:2))
          Button("Etichette"){showLabels=true}.foregroundColor(.red).padding(8)
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.red,lineWidth:2))
        }.padding()
        HStack{
          Button("Condividi Monte Ore"){showShare=true}.foregroundColor(.purple).padding()
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.purple,lineWidth:2))
          Spacer()
          Button("Importa File"){showImport=true}.foregroundColor(.orange).padding()
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.orange,lineWidth:2))
        }.padding(.horizontal)
      }
      .navigationBarTitle("",displayMode:.inline)
      .toolbar{
        ToolbarItem(placement:.navigationBarLeading){ProjectEditToggleButton(isEditing:$editing)}
        ToolbarItem(placement:.navigationBarTrailing){
          if howBtn{Button("Come funziona l'app"){showHow=true}}
          else{Button("?"){howBtn=true}}
        }
      }
      .sheet(isPresented:$showLabels){LabelsManagerView(pm:pm)}
      .sheet(isPresented:$showShare){if let u=pm.exportURL(){ActivityView(activityItems:[u])}else{Text("Errore")}}
      .fileImporter(isPresented:$showImport,allowedContentTypes:[.json]){res in
        switch res{
        case .success(let url): if url.startAccessingSecurityScopedResource(){
          defer{url.stopAccessingSecurityScopedResource()}
          if let d=try?Data(contentsOf:url),
             let imp=try?JSONDecoder().decode(ExportData.self,from:d){
            pending=imp;showImportConfirm=true
          } else{err=AlertError(message:"Import Error")}
        } else{err=AlertError(message:"No Access")}
        case .failure(let e):err=AlertError(message:e.localizedDescription)
        }
      }
      .alert(item:$err){Alert(title:Text("Errore"),message:Text($0.message),dismissButton:.default(Text("OK")))}
      .sheet(isPresented:$showImportConfirm){if let imp=pending{
        ImportConfirmationView(message:"Sovrascrivere? Tutti i progetti saranno persi.",
                               importAction:{
          pm.projects=imp.projects;pm.backupProjects=imp.backupProjects;pm.labels=imp.labels
          if let s=imp.lockedLabelID,let u=UUID(uuidString:s){pm.lockedLabelID=u}else{pm.lockedLabelID=nil}
          pm.currentProject=pm.projects.first;pm.save();pm.saveLabels()
          pending=nil;showImportConfirm=false
        },cancelAction:{pending=nil;showImportConfirm=false})
      } else{Text("No data")}}
      .sheet(isPresented:$showHow,onDismiss:{howBtn=false}){ComeFunzionaSheetView(onDismiss:{showHow=false})}
      .onAppear{NotificationCenter.default.addObserver(forName:.init("CycleProjectNotification"),object:nil,queue:.main){_ in cycle()}}
    }
  }
  private func cycle(){
    let av=pm.lockedLabelID.map{pm.projects.filter{$0.labelID==$0}} ?? pm.projects
    guard let cur=pm.currentProject, let idx=av.firstIndex(where:{ $0.id==cur.id }), av.count>1 else{return}
    let next=av[(idx+1)%av.count]
    pm.currentProject=next
  }
}

// Main ContentView
struct ContentView:View{
  @ObservedObject var pm=ProjectManager()
  @State private var showPM=false,showN=false,showPop=false
  @AppStorage("medalAwarded") private var medal=false
  var body: some View{
    GeometryReader{geo in
      let isLand=geo.size.width>geo.size.height
      ZStack{
        Color(hex:"#54c0ff").edgesIgnoringSafeArea(.all)
        VStack(spacing:20){
          if pm.currentProject==nil{
            NoNotesPromptView(onOk:{showPM=true},onNonCHoSbatti:{showN=true})
          } else {
            ScrollView{
              NoteView(project:pm.currentProject!,pm:pm)
            }
            .frame(width:isLand ? geo.size.width:geo.size.width-40,
                   height:isLand ? geo.size.height*0.4:geo.size.height*0.6)
            .background(Color.white.opacity(0.2)).cornerRadius(25).clipped()
          }
          Button("Pigia il tempo"){timeTap() }
            .font(.title2).foregroundColor(.white)
            .frame(width:isLand?90:140,height:isLand?100:140)
            .background(Circle().fill(Color.black))
            .disabled(pm.currentProject==nil || pm.backupProjects.contains(where:{ $0.id==pm.currentProject?.id }))
          HStack{
            Button("Gestione\nProgetti"){showPM=true}
              .font(.headline).multilineTextAlignment(.center)
              .frame(width:isLand?90:140,height:isLand?100:140)
              .background(Circle().fill(Color.white)).overlay(Circle().stroke(Color.black,lineWidth:2))
            Spacer()
            Button("Cambia\nProgetto"){cycle()}
              .font(.headline).multilineTextAlignment(.center)
              .frame(width:isLand?90:140,height:isLand?100:140)
              .background(Circle().fill(Color.yellow)).overlay(Circle().stroke(Color.black,lineWidth:2))
              .disabled(pm.currentProject==nil)
          }.padding(.horizontal,isLand?10:30).padding(.bottom,isLand?0:30)
        }
        if showPop{
          PopupView(message:"Congratulazioni! Hai la medaglia \"Sbattimenti zero eh\"")
            .transition(.scale)
        }
      }
      .sheet(isPresented:$showPM){ProjectManagerView(pm:pm)}
      .sheet(isPresented:$showN){NonCHoSbattiSheetView(onDismiss:{
        if !medal{medal=true;showPop=true;DispatchQueue.main.asyncAfter(deadline:.now()+5){withAnimation{showPop=false}}}
        showN=false
      })}
    }
  }
  private func cycle(){
    let av=pm.lockedLabelID.map{pm.projects.filter{$0.labelID==$0}} ?? pm.projects
    guard let cur=pm.currentProject,let idx=av.firstIndex(where:{ $0.id==cur.id }),av.count>1 else{return}
    pm.currentProject=av[(idx+1)%av.count]
  }
  private func timeTap(){
    guard let p=pm.currentProject else{return}
    let now=Date(),df=DateFormatter();df.locale=Locale(identifier:"it_IT");df.dateFormat="EEEE dd/MM/yy"
    let gs=df.string(from:now).capitalized,tf=DateFormatter();tf.locale=Locale(identifier:"it_IT");tf.dateFormat="HH:mm"
    let ts=tf.string(from:now)
    pm.backupIfNeeded(p)
    if p.noteRows.isEmpty||p.noteRows.last!.giorno!=gs {
      p.noteRows.append(NoteRow(giorno:gs,orari:ts+"-"))
    } else {
      var lr=p.noteRows.popLast()!
      if lr.orari.hasSuffix("-"){lr.orari+=ts}
      else{lr.orari+=" \(ts)-"}
      p.noteRows.append(lr)
    }
    pm.save()
  }
}

struct NoNotesPromptView:View{
  var onOk:()->Void,onNonCHoSbatti:()->Void
  var body:some View{
    VStack(spacing:20){
      Text("Nessun progetto attivo").font(.title).bold()
      Text("Per iniziare, crea o seleziona un progetto.").multilineTextAlignment(.center)
      HStack(spacing:20){
        Button("Crea/Seleziona Progetto",action:onOk)
          .padding().background(Color.blue).foregroundColor(.white).cornerRadius(8)
        Button("Non CHo Sbatti",action:onNonCHoSbatti)
          .padding().background(Color.orange).foregroundColor(.white).cornerRadius(8)
      }
    }.padding().background(Color.white).cornerRadius(12).shadow(radius:8)
  }
}

struct PopupView:View{let message:String;var body:some View{
  Text(message).font(.headline).foregroundColor(.white)
    .padding().background(Color.black.opacity(0.8)).cornerRadius(10).shadow(radius:10)
}}
struct NonCHoSbattiSheetView:View{let onDismiss:()->Void;var body:some View{
  VStack(spacing:20){
    Text("Frate, nemmeno io...").font(.custom("Permanent Marker",size:28)).bold().foregroundColor(.black).multilineTextAlignment(.center)
    Button("Mh",action:onDismiss)
      .font(.title2).foregroundColor(.white).padding().frame(maxWidth:.infinity).background(Color.green).cornerRadius(8)
  }.padding(30)
}}

@main struct MyTimeTrackerApp:App{var body: some Scene{WindowGroup{ContentView()}}}
