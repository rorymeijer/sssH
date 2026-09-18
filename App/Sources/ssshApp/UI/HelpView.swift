import SwiftUI

/// The in-app manual: one page per subject.
///
/// Written into the app rather than pointing at a website, because the person
/// reading it is mid-task — often on the machine whose network is exactly the
/// problem. Everything here works offline.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(HelpTopic.allCases) { topic in
                NavigationLink(value: topic) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            topic.title
                            topic.summary
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: topic.symbol)
                    }
                }
            }
            .navigationDestination(for: HelpTopic.self) { topic in
                HelpTopicView(topic: topic)
            }
            .navigationTitle(Text("Handleiding", comment: "Title of the in-app manual"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 520)
        #endif
    }
}

/// The subjects, in the order someone new needs them: connect first, then the
/// things you do inside a session, then the machinery around it.
enum HelpTopic: CaseIterable, Identifiable, Hashable {
    case gettingStarted
    case sessions
    case blocks
    case snippets
    case tunnels
    case files
    case tmux
    case security
    case shortcuts

    var id: Self { self }

    var title: Text {
        switch self {
        case .gettingStarted:
            return Text("Aan de slag", comment: "Help topic title: getting started")
        case .sessions:
            return Text("Sessies en vensters", comment: "Help topic title: sessions, tabs and panes")
        case .blocks:
            return Text("Opdrachten en zoeken", comment: "Help topic title: command blocks and search")
        case .snippets:
            return Text("Fragmenten", comment: "Title of the snippet library")
        case .tunnels:
            return Text("Tunnels", comment: "Section header: saved port forwards")
        case .files:
            return Text("Bestanden", comment: "Title of the file browser")
        case .tmux:
            return Text("tmux", comment: "Help topic title: tmux control mode")
        case .security:
            return Text("Beveiliging", comment: "Title of the security settings")
        case .shortcuts:
            return Text("Sneltoetsen", comment: "Help topic title: keyboard shortcuts")
        }
    }

    var summary: Text {
        switch self {
        case .gettingStarted:
            return Text("Hosts toevoegen, inloggen en verbinden", comment: "Help topic summary: getting started")
        case .sessions:
            return Text("Tabbladen, splitsen en invoer naar alles tegelijk", comment: "Help topic summary: sessions, tabs and panes")
        case .blocks:
            return Text("Uitvoer per opdracht, en erin zoeken", comment: "Help topic summary: command blocks and search")
        case .snippets:
            return Text("Bewaarde opdrachten met invulvelden", comment: "Help topic summary: snippets")
        case .tunnels:
            return Text("Poorten doorsturen over de verbinding", comment: "Help topic summary: tunnels")
        case .files:
            return Text("Bestanden uitwisselen via SFTP", comment: "Help topic summary: file browser")
        case .tmux:
            return Text("Werk dat een verbroken verbinding overleeft", comment: "Help topic summary: tmux control mode")
        case .security:
            return Text("Waar geheimen staan en wat er synchroniseert", comment: "Help topic summary: security")
        case .shortcuts:
            return Text("Alles wat een toets heeft, op een rij", comment: "Help topic summary: keyboard shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: return "play.circle"
        case .sessions: return "rectangle.split.2x2"
        case .blocks: return "list.bullet.rectangle"
        case .snippets: return "text.badge.plus"
        case .tunnels: return "point.3.filled.connected.trianglepath.dotted"
        case .files: return "folder"
        case .tmux: return "terminal"
        case .security: return "lock.shield"
        case .shortcuts: return "keyboard"
        }
    }
}

/// One manual page: a scrolling column of short sections.
struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch topic {
                case .gettingStarted: gettingStarted
                case .sessions: sessions
                case .blocks: blocks
                case .snippets: snippets
                case .tunnels: tunnels
                case .files: files
                case .tmux: tmux
                case .security: security
                case .shortcuts: shortcuts
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(topic.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder private var gettingStarted: some View {
        HelpSection(title: Text("Een host toevoegen", comment: "Help section title: adding a host")) {
            Text("Klik op + in de zijbalk. De naam is voor jou; adres, poort en gebruikersnaam zijn wat sssH gebruikt om te verbinden. Met groepen, labels en kleuren houd je een lange lijst leesbaar.",
                 comment: "Help: how to add a host")
            Text("Heb je al een ~/.ssh/config? Importeer die via het menu rechtsboven in de zijbalk, dan staan je hosts er in één keer in.",
                 comment: "Help: importing an ssh config")
        }
        HelpSection(title: Text("Inloggen", comment: "Help section title: authentication")) {
            Text("Kies per host een wachtwoord, een privésleutel, of 'elke keer vragen'. Wachtwoorden en sleutels staan in de sleutelhanger van dit apparaat en synchroniseren niet mee. Een nieuwe sleutel genereren kan in de app; zet daarna de publieke sleutel op de server.",
                 comment: "Help: authentication options")
        }
        HelpSection(title: Text("Verbinden", comment: "Help section title: connecting")) {
            Text("Klik op een host, of druk op ⌘K en typ de naam. Bij een eerste verbinding vraagt sssH je de hostsleutel te controleren; daarna waarschuwt het alleen als die verandert.",
                 comment: "Help: how to connect and what the host key prompt is")
        }
        HelpSection(title: Text("Via een bastion", comment: "Help section title: jump hosts")) {
            Text("Is een server alleen via een tussenstap bereikbaar, stel dan een jump host in. Een bastion is gewoon een andere opgeslagen host, en een keten van meerdere sprongen mag.",
                 comment: "Help: jump hosts")
        }
    }

    @ViewBuilder private var sessions: some View {
        HelpSection(title: Text("Tabbladen en splitsen", comment: "Help section title: tabs and splits")) {
            Text("Elke verbinding is een tabblad. Splits een tabblad met ⌘D (naast elkaar) of ⇧⌘D (onder elkaar); elk venster is een eigen shell. Wissel van venster met ⌘⌥[ en ⌘⌥], van tabblad met ⇧⌘{ en ⇧⌘}. Sluit een venster met ⌘W en een heel tabblad met ⇧⌘W.",
                 comment: "Help: tabs, splits and moving focus")
        }
        HelpSection(title: Text("Invoer naar alle vensters", comment: "Menu item: toggle broadcasting input to every pane")) {
            Text("Met ⇧⌘I gaat wat je typt naar elk venster van het tabblad tegelijk — handig voor hetzelfde commando op meerdere servers. Het staat per tabblad aan of uit, en gaat niet stiekem mee naar het volgende.",
                 comment: "Help: input broadcast")
        }
        HelpSection(title: Text("Herstel na opnieuw starten", comment: "Help section title: session restore")) {
            Text("sssH opent bij de start de tabbladen van de vorige keer opnieuw. De verbindingen worden vers opgezet — inclusief eventuele wachtwoordvragen — want een terminal die levend oogt maar het niet is, is erger dan even opnieuw inloggen.",
                 comment: "Help: session restore behaviour")
        }
    }

    @ViewBuilder private var blocks: some View {
        HelpSection(title: Text("Uitvoer per opdracht", comment: "Help section title: command blocks")) {
            Text("Met shell-integratie verdeelt sssH de uitvoer in blokken: per opdracht zie je de opdracht zelf, de uitvoer en of die slaagde. De opdrachtenlijst open je met ⇧⌘B; de integratie stel je vanaf daar in.",
                 comment: "Help: what command blocks are")
        }
        HelpSection(title: Text("Zoeken", comment: "Help section title: searching a session")) {
            Text("⌘F zoekt in de opdrachten én hun uitvoer. Een treffer vertelt ook welke opdracht die uitvoer produceerde — dat is meestal de vraag achter de zoekopdracht.",
                 comment: "Help: session search")
        }
    }

    @ViewBuilder private var snippets: some View {
        HelpSection(title: Text("Wat een fragment is", comment: "Help section title: what a snippet is")) {
            Text("Een fragment is een bewaarde opdracht. Open de bibliotheek met ⇧⌘S in een sessie, of via het menu in de zijbalk om te beheren. Klik op een fragment om het naar de terminal te sturen.",
                 comment: "Help: what snippets are and how to open the library")
        }
        HelpSection(title: Text("Invulvelden", comment: "Section header listing a snippet's placeholders")) {
            Text("Schrijf {{naam}} in een opdracht en sssH vraagt om een waarde vóór het versturen; {{naam=standaard}} vult er alvast een in. Je ziet altijd eerst precies wat er verstuurd gaat worden. Accolades in shell-scripts blijven gewoon staan.",
                 comment: "Help: snippet placeholders")
        }
        HelpSection(title: Text("Uitvoeren of alleen typen", comment: "Help section title: run immediately or type only")) {
            Text("Staat 'direct uitvoeren' uit, dan wordt de opdracht alleen getypt zodat je die eerst kunt nalezen — het verschil tussen een sneltoets en een gok. Pin een fragment aan een host als het alleen daar thuishoort; zonder pin is het overal beschikbaar.",
                 comment: "Help: runs-immediately toggle and host pinning")
            Text("Fragmenten staan ook in het palet (⌘K): eentje zonder invulvelden wordt van daaruit direct verstuurd.",
                 comment: "Help: snippets in the command palette")
        }
    }

    @ViewBuilder private var tunnels: some View {
        HelpSection(title: Text("Drie soorten", comment: "Help section title: tunnel kinds")) {
            Text("Een tunnel stuurt een poort door over de SSH-verbinding. sssH kent dezelfde drie als ssh: -L brengt een poort van de server naar dit apparaat, -R andersom, en -D maakt een SOCKS5-proxy die al je verkeer via de server stuurt.",
                 comment: "Help: the three tunnel kinds")
        }
        HelpSection(title: Text("Gebruik", comment: "Help section title: using tunnels")) {
            Text("Tunnels horen bij een host en kunnen automatisch starten zodra die verbindt. Het paneel open je met ⌘⌥T. Poort 0 laat het systeem een vrije poort kiezen; die zie je zodra de tunnel loopt.",
                 comment: "Help: saving and starting tunnels")
            Text("Tunnels luisteren standaard alleen op 127.0.0.1 — alleen dit apparaat kan erbij. Kies je een ander adres, dan is de tunnel voor het hele netwerk bereikbaar, en dat zegt sssH er dan nadrukkelijk bij.",
                 comment: "Help: tunnel listen address safety")
        }
    }

    @ViewBuilder private var files: some View {
        HelpSection(title: Text("De bestandsbrowser", comment: "Help section title: the file browser")) {
            Text("Open de bestandsbrowser met ⌘⌥B: dit apparaat links, de server rechts, over dezelfde verbinding als de terminal (SFTP) — geen tweede keer inloggen.",
                 comment: "Help: opening the file browser")
            Text("Sleep bestanden tussen de panelen om te uploaden of te downloaden. De wachtrij toont de voortgang en wat er nog komt.",
                 comment: "Help: transferring files")
        }
    }

    @ViewBuilder private var tmux: some View {
        HelpSection(title: Text("Control mode", comment: "Help section title: tmux control mode")) {
            Text("Zet 'tmux control mode' aan bij een host en sssH start tmux -CC bij het verbinden. De vensters en panes van tmux worden gewone tabbladen en splitsingen van sssH — geen statusbalk-in-een-terminal.",
                 comment: "Help: what tmux control mode does")
        }
        HelpSection(title: Text("Waarom je dit wilt", comment: "Help section title: why tmux control mode")) {
            Text("Het werk draait op de server. Valt de verbinding weg, dan draait alles gewoon door en pak je het na opnieuw verbinden op waar je was. Eén sessienaam per host betekent terugkeren naar dezelfde sessie in plaats van een stapel anonieme.",
                 comment: "Help: tmux survives disconnects")
        }
    }

    @ViewBuilder private var security: some View {
        HelpSection(title: Text("Waar geheimen staan", comment: "Help section title: where secrets live")) {
            Text("Wachtwoorden, privésleutels en wachtwoordzinnen staan in de sleutelhanger, beschermd door het apparaat. De hostconfiguratie zelf synchroniseert via iCloud; geheimen gaan alleen mee als je dat expliciet aanzet in de beveiligingsinstellingen.",
                 comment: "Help: secrets in the keychain versus synced configuration")
        }
        HelpSection(title: Text("Vergrendelen", comment: "Help section title: app lock")) {
            Text("Vergrendel de app direct met ⌃⌘L, of automatisch wanneer die naar de achtergrond gaat. Ontgrendelen gaat met Touch ID of Face ID. Instellen bij Beveiliging.",
                 comment: "Help: locking the app")
        }
        HelpSection(title: Text("Hostsleutels", comment: "Help section title: host keys")) {
            Text("Een hostsleutel die je goedkeurt wordt onthouden en gesynchroniseerd, zodat een véranderde sleutel — het signaal dat ertoe doet — op elk apparaat opvalt.",
                 comment: "Help: known host keys")
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            shortcutRow("⌘K", Text("Ga naar…", comment: "Menu item: open the command palette"))
            shortcutRow("⌘D ⇧⌘D", Text("Splits naar rechts, naar beneden", comment: "Help shortcut: split the pane"))
            shortcutRow("⌘⌥[ ⌘⌥]", Text("Vorig, volgend venster", comment: "Help shortcut: previous and next pane"))
            shortcutRow("⇧⌘{ ⇧⌘}", Text("Vorige, volgende sessie", comment: "Help shortcut: previous and next tab"))
            shortcutRow("⌘W ⇧⌘W", Text("Sluit venster, sluit sessie", comment: "Help shortcut: close pane and close tab"))
            shortcutRow("⇧⌘I", Text("Invoer naar alle vensters", comment: "Menu item: toggle broadcasting input to every pane"))
            shortcutRow("⌘F", Text("Zoek in sessie…", comment: "Menu item: search the current session's commands and output"))
            shortcutRow("⇧⌘B", Text("Opdrachten", comment: "Menu item: toggle the command block list"))
            shortcutRow("⇧⌘S", Text("Fragmenten", comment: "Title of the snippet library"))
            shortcutRow("⌘⌥T", Text("Tunnels", comment: "Section header: saved port forwards"))
            shortcutRow("⌘⌥B", Text("Bestanden", comment: "Title of the file browser"))
            shortcutRow("⌘+ ⌘− ⌘0", Text("Tekstgrootte: groter, kleiner, normaal", comment: "Help shortcut: terminal text size"))
            shortcutRow("⌃⌘L", Text("Vergrendel sssH", comment: "Menu item that locks the app now"))
        }
    }

    private func shortcutRow(_ keys: String, _ label: Text) -> some View {
        GridRow {
            Text(verbatim: keys)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            label
        }
    }
}

/// A titled run of paragraphs, so every page reads the same way.
private struct HelpSection<Content: View>: View {
    let title: Text
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
