//
//  Server.swift
//  Postgres
//
//  Created by Chris on 01/07/16.
//  Copyright © 2016 postgresapp. All rights reserved.
//

import Cocoa

class Server: NSObject {
	
	static let VersionsPath = "/Applications/Postgres.app/Contents/Versions"
	static let PropertyChangedNotification = Notification.Name("Server.PropertyChangedNotification")
	static let StatusChangedNotification   = Notification.Name("Server.StatusChangedNotification")
	
	@objc enum ServerStatus: Int {
		case noBinaries
		case portInUse
		case dataDirInUse
		case dataDirEmpty
		case running
		case startable
		case stalePidFile
		case pidFileUnreadable
		case unknown
	}
	
	enum ActionStatus {
		case success
		case failure(NSError)
	}
	
	
	@objc dynamic var name: String = "" {
		didSet {
			NotificationCenter.default.post(name: Server.PropertyChangedNotification, object: self)
		}
	}
	@objc dynamic var port: UInt = 0 {
		didSet {
			NotificationCenter.default.post(name: Server.PropertyChangedNotification, object: self)
		}
	}
	@objc dynamic var binPath: String = ""
	@objc dynamic var varPath: String = ""
	@objc dynamic var startOnLogin: Bool = false {
		didSet {
			NotificationCenter.default.post(name: Server.PropertyChangedNotification, object: self)
		}
	}
	@objc dynamic var configFilePath: String {
		return varPath.appending("/postgresql.conf")
	}
	@objc dynamic var hbaFilePath: String {
		return varPath.appending("/pg_hba.conf")
	}
	@objc dynamic var logFilePath: String {
		return varPath.appending("/postgresql.log")
	}
	private var pidFilePath: String {
		return varPath.appending("/postmaster.pid")
	}
	private var pgVersionPath: String {
		return varPath.appending("/PG_VERSION")
	}
	
	@objc dynamic private(set) var busy: Bool = false
	@objc dynamic private(set) var running: Bool = false
	@objc dynamic private(set) var serverStatus: ServerStatus = .unknown
	@objc dynamic private(set) var databases: [Database] = []
	@objc dynamic var selectedDatabaseIndices = IndexSet()
	
	var firstSelectedDatabase: Database? {
		guard let firstIndex = selectedDatabaseIndices.first else { return nil }
		return databases[firstIndex]
	}
	
	var asPropertyList: [AnyHashable: Any] {
		var result: [AnyHashable: Any] = [:]
		result["name"] = self.name
		result["port"] = self.port
		result["binPath"] = self.binPath
		result["varPath"] = self.varPath
		result["startOnLogin"] = self.startOnLogin
		return result
	}
	
	
	init(name: String, version: String? = nil, port: UInt = 5432, varPath: String? = nil, startOnLogin: Bool = false) {
		super.init()
		let effectiveVersion = version ?? Bundle.main.object(forInfoDictionaryKey: "LatestStablePostgresVersion") as! String
		self.name = name
		self.port = port
		self.binPath = Server.VersionsPath.appendingFormat("/%@/bin", effectiveVersion)
		self.varPath = varPath ?? FileManager().applicationSupportDirectoryPath().appendingFormat("/var-%@", effectiveVersion)
		self.startOnLogin = startOnLogin
		updateServerStatus()
	}
	
	init?(propertyList: [AnyHashable: Any]) {
		guard let name = propertyList["name"] as? String,
		let port = propertyList["port"] as? UInt,
		let binPath = propertyList["binPath"] as? String,
		let varPath = propertyList["varPath"] as? String
		else {
			return nil
		}
		self.name = name
		self.port = port
		self.binPath = binPath
		self.varPath = varPath
		self.startOnLogin = propertyList["startOnLogin"] as? Bool ?? false
	}
	
	
	// MARK: Async handlers
	func start(_ completion: @escaping (ActionStatus) -> Void) {
		busy = true
		updateServerStatus()
		
		DispatchQueue.global().async {
			let statusResult: ActionStatus
			
			switch self.serverStatus {
			
			case .noBinaries:
				let userInfo = [
					NSLocalizedDescriptionKey: NSLocalizedString("The binaries for this PostgreSQL server were not found", comment: ""),
				]
				statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
				
			case .portInUse:
				let userInfo = [
					NSLocalizedDescriptionKey: NSLocalizedString("Port \(self.port) is already in use", comment: ""),
					NSLocalizedRecoverySuggestionErrorKey: "Usually this means that there is already a PostgreSQL server running on your Mac. If you want to run multiple servers simultaneously, use different ports."
				]
				statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
				
			case .dataDirInUse:
				let userInfo = [
					NSLocalizedDescriptionKey: NSLocalizedString("There is already a PostgreSQL server running in this data directory", comment: ""),
				]
				statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
				
			case .dataDirEmpty:
				if self.portInUse() {
					let userInfo = [
						NSLocalizedDescriptionKey: NSLocalizedString("Port \(self.port) is already in use", comment: ""),
						NSLocalizedRecoverySuggestionErrorKey: "Usually this means that there is already a PostgreSQL server running on your Mac. If you want to run multiple servers simultaneously, use different ports."
					]
					statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
					break
				}
				
				let initResult = self.initDatabaseSync()
				if case .failure = initResult {
					statusResult = initResult
					break
				}
				
				let startResult = self.startSync()
				if case .failure = startResult {
					statusResult = startResult
					break
				}
				
				let createUserResult = self.createUserSync()
				guard case .success = createUserResult else {
					statusResult = createUserResult
					break
				}
				
				let createDBResult = self.createUserDatabaseSync()
				if case .failure = createDBResult {
					statusResult = createDBResult
					break
				}
				
				statusResult = .success
				
			case .running:
				statusResult = .success
				
			case .startable:
				let startRes = self.startSync()
				statusResult = startRes
				
			case .stalePidFile:
				let userInfo = [
					NSLocalizedDescriptionKey: NSLocalizedString("The data directory contains an old postmaster.pid file", comment: ""),
					NSLocalizedRecoverySuggestionErrorKey: "The data directory contains a postmaster.pid file, which usually means that the server is already running. When the server crashes or is killed, you have to remove this file before you can restart the server. Make sure that the database process is definitely not runnnig anymore, otherwise your data directory will be corrupted."
				]
				statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
				
			case .pidFileUnreadable:
				let userInfo = [
					NSLocalizedDescriptionKey: NSLocalizedString("The data directory contains an unreadable postmaster.pid file", comment: "")
				]
				statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
				
			case .unknown:
				let userInfo = [
					NSLocalizedDescriptionKey: NSLocalizedString("Unknown server status", comment: "")
				]
				statusResult = .failure(NSError(domain: "com.postgresapp.Postgres2.server-status", code: 0, userInfo: userInfo))
				
			}
			
			DispatchQueue.main.async {
				self.updateServerStatus()
				completion(statusResult)
				self.busy = false
			}
			
		}
	}
	
	
	/// Attempts to stop the server (in a background thread)
	/// - parameter completion: This closure will be called on the main thread when the server has stopped.
	func stop(_ completion: @escaping (ActionStatus) -> Void) {
		busy = true
		
		DispatchQueue.global().async {
			let stopRes = self.stopSync()
			DispatchQueue.main.async {
				self.updateServerStatus()
				completion(stopRes)
				self.busy = false
			}
		}
	}
	
	
	/// Checks if the server is running.
	/// Must be called only from the main thread.
	func updateServerStatus() {
		if !FileManager.default.fileExists(atPath: binPath) {
			serverStatus = .noBinaries
			running = false
			databases.removeAll()
			return
		}
		
		if !FileManager.default.fileExists(atPath: pgVersionPath) {
			serverStatus = .dataDirEmpty
			running = false
			databases.removeAll()
			return
		}
		
		if FileManager.default.fileExists(atPath: pidFilePath) {
			guard let pidFileContents = try? String(contentsOfFile: pidFilePath, encoding: .utf8) else {
				serverStatus = .pidFileUnreadable
				running = false
				databases.removeAll()
				return
			}
			
			let firstLine = pidFileContents.components(separatedBy: .newlines).first!
			guard let pid = Int32(firstLine) else {
				serverStatus = .pidFileUnreadable
				running = false
				databases.removeAll()
				return
			}
			
			var buffer = [CChar](repeating: 0, count: 1024)
			proc_pidpath(pid, &buffer, UInt32(buffer.count))
			let processPath = String(cString: buffer)
			
			if processPath == binPath.appending("/postgres") {
				serverStatus = .running
				running = true
				databases.removeAll()
				loadDatabases()
				return
			}
			else if processPath.hasSuffix("postgres") || processPath.hasSuffix("postmaster") {
				serverStatus = .dataDirInUse
				running = false
				databases.removeAll()
				return
			}
			else if !processPath.isEmpty {
				serverStatus = .stalePidFile
				running = false
				databases.removeAll()
				return
			}
		}
		
		if portInUse() {
			serverStatus = .portInUse
			running = false
			databases.removeAll()
			return
		}
		
		serverStatus = .startable
		running = false
		databases.removeAll()
	}
	
	
	/// Checks if the port is in use by another process.
	private func portInUse() -> Bool {
		let sock = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)
		if sock <= 0 {
			return false
		}
		
		var listenAddress = sockaddr_in()
		listenAddress.sin_family = UInt8(AF_INET)
		listenAddress.sin_port = in_port_t(port).bigEndian
		listenAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		listenAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
		
		let bindRes = withUnsafePointer(to: &listenAddress) { (sockaddrPointer: UnsafePointer<sockaddr_in>) in
			sockaddrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer2 in
				Darwin.bind(sock, sockaddrPointer2, socklen_t(MemoryLayout<sockaddr_in>.stride))
			}
		}
		
		let bindErr = Darwin.errno
		close(sock)
		
		if bindRes == -1 && bindErr == EADDRINUSE {
			return true
		}
		
		return false
	}
	
	
	/// Loads the databases from the servers.
	private func loadDatabases() {
		databases.removeAll()
		
		let url = "postgresql://:\(port)"
		let connection = PQconnectdb(url.cString(using: .utf8))
		
		if PQstatus(connection) == CONNECTION_OK {
			let result = PQexec(connection, "SELECT datname FROM pg_database WHERE datallowconn ORDER BY LOWER(datname)")
			for i in 0..<PQntuples(result) {
				guard let value = PQgetvalue(result, i, 0) else { continue }
				let name = String(cString: value)
				databases.append(Database(name))
			}
			PQclear(result)
		}
		PQfinish(connection)
	}
	
	
	// MARK: Sync handlers
	func startSync() -> ActionStatus {
		let process = Process()
		let launchPath = binPath.appending("/pg_ctl")
		guard FileManager().fileExists(atPath: launchPath) else {
			let userInfo: [String: Any] = [
				NSLocalizedDescriptionKey: NSLocalizedString("The binaries for this PostgreSQL server were not found.", comment: ""),
			]
			return .failure(NSError(domain: "com.postgresapp.Postgres2.pg_ctl", code: 0, userInfo: userInfo))
		}
		process.launchPath = launchPath
		process.arguments = [
			"start",
			"-D", varPath,
			"-w",
			"-l", logFilePath,
			"-o", String("-p \(port)"),
		]
		process.standardOutput = Pipe()
		let errorPipe = Pipe()
		process.standardError = errorPipe
		process.launch()
		let errorDescription = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "(incorrectly encoded error message)"
		process.waitUntilExit()
		
		if process.terminationStatus == 0 {
			return .success
		} else {
			let userInfo: [String: Any] = [
				NSLocalizedDescriptionKey: NSLocalizedString("Could not start PostgreSQL server.", comment: ""),
				NSLocalizedRecoverySuggestionErrorKey: errorDescription,
				NSLocalizedRecoveryOptionsErrorKey: ["OK", "Open Server Log"],
				NSRecoveryAttempterErrorKey: ErrorRecoveryAttempter(recoveryAttempter: { (error, optionIndex) -> Bool in
					if optionIndex == 1 {
						NSWorkspace.shared.openFile(self.logFilePath, withApplication: "Console")
					}
					return true
				})
			]
			return .failure(NSError(domain: "com.postgresapp.Postgres2.pg_ctl", code: 0, userInfo: userInfo))
		}
	}
	
	
	func stopSync() -> ActionStatus {
		let process = Process()
		process.launchPath = binPath.appending("/pg_ctl")
		process.arguments = [
			"stop",
			"-m", "f",
			"-D", varPath,
			"-w",
		]
		process.standardOutput = Pipe()
		let errorPipe = Pipe()
		process.standardError = errorPipe
		process.launch()
		let errorDescription = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "(incorrectly encoded error message)"
		process.waitUntilExit()
		
		if process.terminationStatus == 0 {
			return .success
		} else {
			let userInfo: [String: Any] = [
				NSLocalizedDescriptionKey: NSLocalizedString("Could not stop PostgreSQL server.", comment: ""),
				NSLocalizedRecoverySuggestionErrorKey: errorDescription,
				NSLocalizedRecoveryOptionsErrorKey: ["OK", "Open Server Log"],
				NSRecoveryAttempterErrorKey: ErrorRecoveryAttempter(recoveryAttempter: { (error, optionIndex) -> Bool in
					if optionIndex == 1 {
						NSWorkspace.shared.openFile(self.logFilePath, withApplication: "Console")
					}
					return true
				})
			]
			return .failure(NSError(domain: "com.postgresapp.Postgres2.pg_ctl", code: 0, userInfo: userInfo))
		}
	}
	
	
	private func initDatabaseSync() -> ActionStatus {
		let process = Process()
		process.launchPath = binPath.appending("/initdb")
		process.arguments = [
			"-D", varPath,
			"-U", "postgres",
			"--encoding=UTF-8",
			"--locale=en_US.UTF-8"
		]
		process.standardOutput = Pipe()
		let errorPipe = Pipe()
		process.standardError = errorPipe
		process.launch()
		let errorDescription = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "(incorrectly encoded error message)"
		process.waitUntilExit()
		
		if process.terminationStatus == 0 {
			return .success
		} else {
			let userInfo: [String: Any] = [
				NSLocalizedDescriptionKey: NSLocalizedString("Could not initialize database cluster.", comment: ""),
				NSLocalizedRecoverySuggestionErrorKey: errorDescription,
				NSLocalizedRecoveryOptionsErrorKey: ["OK", "Open Server Log"],
				NSRecoveryAttempterErrorKey: ErrorRecoveryAttempter(recoveryAttempter: { (error, optionIndex) -> Bool in
					if optionIndex == 1 {
						NSWorkspace.shared.openFile(self.logFilePath, withApplication: "Console")
					}
					return true
				})
			]
			return .failure(NSError(domain: "com.postgresapp.Postgres2.initdb", code: 0, userInfo: userInfo))
		}
	}
	
	
	private func createUserSync() -> ActionStatus {
		let process = Process()
		process.launchPath = binPath.appending("/createuser")
		process.arguments = [
			"-U", "postgres",
			"-p", String(port),
			"--superuser",
			NSUserName()
		]
		process.standardOutput = Pipe()
		let errorPipe = Pipe()
		process.standardError = errorPipe
		process.launch()
		let errorDescription = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "(incorrectly encoded error message)"
		process.waitUntilExit()
		
		if process.terminationStatus == 0 {
			return .success
		} else {
			let userInfo: [String: Any] = [
				NSLocalizedDescriptionKey: NSLocalizedString("Could not create default user.", comment: ""),
				NSLocalizedRecoverySuggestionErrorKey: errorDescription,
				NSLocalizedRecoveryOptionsErrorKey: ["OK", "Open Server Log"],
				NSRecoveryAttempterErrorKey: ErrorRecoveryAttempter(recoveryAttempter: { (error, optionIndex) -> Bool in
					if optionIndex == 1 {
						NSWorkspace.shared.openFile(self.logFilePath, withApplication: "Console")
					}
					return true
				})
			]
			return .failure(NSError(domain: "com.postgresapp.Postgres2.createuser", code: 0, userInfo: userInfo))
		}
	}
	
	
	private func createUserDatabaseSync() -> ActionStatus {
		let process = Process()
		process.launchPath = binPath.appending("/createdb")
		process.arguments = [
			"-p", String(port),
			NSUserName()
		]
		process.standardOutput = Pipe()
		let errorPipe = Pipe()
		process.standardError = errorPipe
		process.launch()
		let errorDescription = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "(incorrectly encoded error message)"
		process.waitUntilExit()
		
		if process.terminationStatus == 0 {
			return .success
		} else {
			let userInfo: [String: Any] = [
				NSLocalizedDescriptionKey: NSLocalizedString("Could not create user database.", comment: ""),
				NSLocalizedRecoverySuggestionErrorKey: errorDescription,
				NSLocalizedRecoveryOptionsErrorKey: ["OK", "Open Server Log"],
				NSRecoveryAttempterErrorKey: ErrorRecoveryAttempter(recoveryAttempter: { (error, optionIndex) -> Bool in
					if optionIndex == 1 {
						NSWorkspace.shared.openFile(self.logFilePath, withApplication: "Console")
					}
					return true
				})
			]
			return .failure(NSError(domain: "com.postgresapp.Postgres2.createdb", code: 0, userInfo: userInfo))
		}
	}
	
}



class Database: NSObject {
	@objc dynamic var name: String = ""
	
	init(_ name: String) {
		super.init()
		self.name = name
	}
}

