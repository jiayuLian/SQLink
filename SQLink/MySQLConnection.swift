import Foundation
import Darwin
import Security

/// A pure-Swift MySQL client. All blocking I/O runs on a dedicated serial queue;
/// the `async` methods bridge to Swift concurrency via continuations.
final class MySQLConnection {
    let profile: ConnectionProfile

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private let queue = DispatchQueue(label: "com.jiayu.sqlink.mysql")
    private var sequence: UInt8 = 0
    private var isTLS = false
    private let maxRows = 2000

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    deinit { close() }

    // MARK: - Async bridge
    private func run<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try block()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - Public async API
    func connect(password: String) async throws {
        try await run { try self._connect(password: password) }
    }

    func query(_ sql: String) async throws -> QueryResult {
        try await run { try self._query(sql) }
    }

    func listDatabases() async throws -> [String] {
        try await run {
            let r = try self._query("SHOW DATABASES")
            guard case .result(_, let rows) = r else { return [] }
            return rows.compactMap { $0.first ?? nil }
        }
    }

    func listTables(db: String) async throws -> [(name: String, type: String)] {
        try await run {
            let r = try self._query("SHOW FULL TABLES FROM `\(self.esc(db))`")
            guard case .result(_, let rows) = r else { return [] }
            return rows.compactMap { row in
                guard row.count >= 2, let n = row[0] else { return nil }
                return (n, row[1] ?? "BASE TABLE")
            }
        }
    }

    func listColumns(db: String, table: String) async throws -> [ColumnInfo] {
        try await run {
            // NOTE: use plain SHOW COLUMNS (not FULL) so column indices match:
            // 0 Field, 1 Type, 2 Null, 3 Key, 4 Default, 5 Extra
            let r = try self._query("SHOW COLUMNS FROM `\(self.esc(db))`.`\(self.esc(table))`")
            guard case .result(_, let rows) = r else { return [] }
            return rows.map { row in
                ColumnInfo(
                    field: row[0] ?? "",
                    type: row[1] ?? "",
                    null: row[2] ?? "",
                    key: row[3] ?? "",
                    default: row[4] ?? "",
                    extra: row[5] ?? ""
                )
            }
        }
    }

    func countRows(db: String, table: String, whereClause: String? = nil) async throws -> Int {
        try await run {
            var sql = "SELECT COUNT(*) FROM `\(self.esc(db))`.`\(self.esc(table))`"
            if let w = whereClause, !w.isEmpty { sql += " WHERE \(w)" }
            let r = try self._query(sql)
            guard case .result(_, let rows) = r,
                  let first = rows.first,
                  let raw = first.first else { return 0 }
            return Int(raw ?? "0") ?? 0
        }
    }

    func preview(db: String, table: String, limit: Int = 100,
                 whereClause: String? = nil, orderBy: String? = nil) async throws -> QueryResult {
        try await run {
            var sql = "SELECT * FROM `\(self.esc(db))`.`\(self.esc(table))`"
            if let w = whereClause, !w.isEmpty { sql += " WHERE \(w)" }
            if let o = orderBy, !o.isEmpty { sql += " ORDER BY \(o)" }
            sql += " LIMIT \(limit)"
            return try self._query(sql)
        }
    }

    func distinctValues(db: String, table: String, column: String, limit: Int = 100) async throws -> [String] {
        try await run {
            let sql = "SELECT DISTINCT `\(self.esc(column))` FROM `\(self.esc(db))`.`\(self.esc(table))` ORDER BY `\(self.esc(column))` LIMIT \(limit)"
            let r = try self._query(sql)
            guard case .result(_, let rows) = r else { return [] }
            return rows.compactMap { $0.first ?? nil }
        }
    }

    func escValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "'", with: "\\'")
    }

    func close() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "``")
    }

    // MARK: - Connect + handshake (sync)
    private func _connect(password: String) throws {
        let fd = try connectTCP(host: profile.host, port: profile.port)
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, fd, &readStream, &writeStream)
        guard let rs = readStream?.takeRetainedValue(),
              let ws = writeStream?.takeRetainedValue() else {
            Darwin.close(fd)
            throw MySQLError.connectionFailed("无法创建网络流")
        }
        let input = rs as InputStream
        let output = ws as OutputStream
        let closeKey = Stream.PropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket as String)
        input.setProperty(kCFBooleanTrue, forKey: closeKey)
        output.setProperty(kCFBooleanTrue, forKey: closeKey)
        input.open()
        output.open()
        inputStream = input
        outputStream = output

        isTLS = false
        let greeting = try readPacket()
        let (scramble, pluginName, _) = try parseGreeting(greeting)
        try performHandshake(scramble: scramble, pluginName: pluginName, password: password)
        sequence = 0
    }

    private func connectTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let service = "\(port)"
        guard getaddrinfo(host, service, &hints, &res) == 0, res != nil else {
            throw MySQLError.connectionFailed("无法解析主机 \(host)")
        }
        defer { if let r = res { freeaddrinfo(r) } }

        var fd: Int32 = -1
        var cur: UnsafeMutablePointer<addrinfo>? = res
        while let c = cur {
            fd = socket(c.pointee.ai_family, c.pointee.ai_socktype, c.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, c.pointee.ai_addr, c.pointee.ai_addrlen) == 0 { break }
                Darwin.close(fd); fd = -1
            }
            cur = c.pointee.ai_next
        }
        if fd < 0 { throw MySQLError.connectionFailed("无法连接到 \(host):\(port)") }

        var tv = timeval()
        tv.tv_sec = 30
        tv.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    // MARK: - Greeting parse
    private func parseGreeting(_ g: [UInt8]) throws -> (scramble: [UInt8], pluginName: String, serverCap: UInt32) {
        guard g.count > 0, g[0] == 10 else {
            throw MySQLError.handshakeFailed("不支持的协议版本（期望 10）")
        }
        var i = 1
        let _ = readCString(g, i) // server version, unused
        i = 1
        while i < g.count, g[i] != 0 { i += 1 }
        i += 1 // skip NUL
        i += 4 // thread id
        guard i + 8 <= g.count else { throw MySQLError.handshakeFailed("握手数据不完整") }
        var scramble = Array(g[i..<i + 8]); i += 8
        i += 1 // filler
        let capLow = UInt32(g[i]) | UInt32(g[i + 1]) << 8; i += 2
        i += 1 // charset
        i += 2 // status
        let capHigh = UInt32(g[i]) | UInt32(g[i + 1]) << 8; i += 2
        let serverCap = capLow | (capHigh << 16)
        let authDataLen = Int(g[i]); i += 1
        i += 10 // reserved
        let part2Len = max(0, authDataLen - 8)
        let end = min(i + part2Len, g.count)
        scramble.append(contentsOf: g[i..<end]); i = end
        var pluginName = "mysql_native_password"
        if serverCap & cap(.pluginAuth) != 0, i < g.count {
            let (name, _) = readCString(g, i)
            if !name.isEmpty { pluginName = name }
        }
        while scramble.last == 0 { scramble.removeLast() }
        return (scramble, pluginName, serverCap)
    }

    // MARK: - Handshake + auth
    private func performHandshake(scramble: [UInt8], pluginName: String, password: String) throws {
        let usePlugin = pluginName

        var clientCap: UInt32 = 0
        clientCap |= cap(.longPassword)
        clientCap |= cap(.longFlag)
        clientCap |= cap(.protocol41)
        clientCap |= cap(.pluginAuth)
        clientCap |= cap(.secureConnection)
        clientCap |= cap(.multiResults)
        clientCap |= cap(.pluginAuthLenencClientData)
        if !profile.database.isEmpty { clientCap |= cap(.connectWithDB) }
        if profile.useTLS { clientCap |= cap(.ssl) }

        let authResponse: [UInt8]
        if usePlugin == "mysql_native_password" {
            authResponse = password.isEmpty ? [] : mysqlNativePassword(password: [UInt8](password.utf8), scramble: scramble)
        } else {
            // caching_sha2_password: initial response = XOR(SHA256(pwd), SHA256(scramble + SHA256(SHA256(pwd))))
            authResponse = password.isEmpty ? [] : cachingSha2Password(password: [UInt8](password.utf8), scramble: scramble)
        }

        if profile.useTLS {
            // SSL request packet (capabilities with CLIENT_SSL, no auth data)
            self.sequence = 1
            var sslReq: [UInt8] = []
            sslReq += withUnsafeBytes(of: clientCap.littleEndian) { Array($0) }
            sslReq += withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }
            sslReq += [45] // utf8mb4
            sslReq += [UInt8](repeating: 0, count: 23)
            try writePacket(sslReq)
            try upgradeTLS(allowSelfSigned: profile.trustSelfSigned)
            isTLS = true
            self.sequence = 2
        } else {
            self.sequence = 1
        }

        // Handshake response (without CLIENT_SSL once TLS is active)
        // Format: cap(4) + maxPacket(4) + charset(1) + reserved(23) + username\0 + authResponse(lenEnc) + db\0 + plugin\0
        var payload: [UInt8] = []
        payload += withUnsafeBytes(of: (clientCap & ~cap(.ssl)).littleEndian) { Array($0) }
        payload += withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }
        payload += [45]
        payload += [UInt8](repeating: 0, count: 23)
        payload += [UInt8](profile.user.utf8)
        payload.append(0)
        payload += lenEncData(authResponse)
        if !profile.database.isEmpty {
            payload += [UInt8](profile.database.utf8)
            payload.append(0)
        }
        payload += [UInt8](usePlugin.utf8)
        payload.append(0)
        try writePacket(payload)

        try handleAuthResult(password: password, initialScramble: scramble)
    }

    private func upgradeTLS(allowSelfSigned: Bool) throws {
        let sslSettings: [String: Any] = [
            kCFStreamSSLValidatesCertificateChain as String: (allowSelfSigned ? kCFBooleanFalse : kCFBooleanTrue) as Any,
            kCFStreamSSLPeerName as String: kCFNull as Any
        ]
        let levelKey = Stream.PropertyKey(rawValue: kCFStreamPropertySocketSecurityLevel as String)
        let settingsKey = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        inputStream?.setProperty(kCFStreamSocketSecurityLevelNegotiatedSSL, forKey: levelKey)
        outputStream?.setProperty(kCFStreamSocketSecurityLevelNegotiatedSSL, forKey: levelKey)
        inputStream?.setProperty(sslSettings, forKey: settingsKey)
        outputStream?.setProperty(sslSettings, forKey: settingsKey)
    }

    private func handleAuthResult(password: String, initialScramble: [UInt8]) throws {
        var currentScramble = initialScramble
        while true {
            let pkt = try readPacket()
            guard !pkt.isEmpty else { throw MySQLError.authFailed("服务器返回空响应") }
            let first = pkt[0]
            if first == 0x00 { return }
            if first == 0xFF {
                let (code, msg) = parseError(pkt)
                throw MySQLError.serverError(code: code, message: msg)
            }
            if first == 0x01 {
                guard pkt.count >= 2 else { throw MySQLError.authFailed("AuthMoreData 数据异常") }
                let sub = pkt[1]
                if sub == 0x03 {
                    // fast auth success indicator: next packet should be OK
                    continue
                }
                if sub == 0x04 {
                    // full authentication required
                    if isTLS {
                        try writePacket(lenEncData([UInt8](password.utf8)))
                        continue
                    } else {
                        try writePacket([0x02]) // request public key
                        let pubPkt = try readPacket()
                        guard pubPkt.count > 1, pubPkt[0] == 0x01 else { throw MySQLError.authFailed("未收到服务器公钥") }
                        let der = Array(pubPkt[1...])
                        let enc = try rsaEncryptPassword(password: password, scramble: currentScramble, der: der)
                        try writePacket(lenEncData(enc))
                        continue
                    }
                }
                throw MySQLError.authFailed("不支持的 AuthMoreData 子类型 \(sub)")
            }
            if first == 0xFE {
                // Auth Switch Request: [0xFE, plugin_name\0, auth_plugin_data...]
                var i = 1
                let (newPlugin, next) = readCString(pkt, i)
                i = next
                let newScramble = Array(pkt[i...])
                if !newScramble.isEmpty { currentScramble = newScramble }
                let pwdBytes = [UInt8](password.utf8)
                let response: [UInt8]
                if newPlugin == "mysql_native_password" {
                    response = password.isEmpty ? [] : mysqlNativePassword(password: pwdBytes, scramble: newScramble)
                } else if newPlugin == "caching_sha2_password" {
                    response = password.isEmpty ? [] : cachingSha2Password(password: pwdBytes, scramble: newScramble)
                } else {
                    throw MySQLError.authFailed("服务器请求不支持的认证插件：\(newPlugin)")
                }
                try writePacket(lenEncData(response))
                continue
            }
            throw MySQLError.authFailed("认证响应异常 (0x\(String(first, radix: 16)))")
        }
    }

    private func rsaEncryptPassword(password: String, scramble: [UInt8], der: [UInt8]) throws -> [UInt8] {
        let data = Data(der)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                &error), error == nil else {
            throw MySQLError.authFailed("无法解析服务器公钥（请改用 TLS 或 mysql_native_password 账号）")
        }

        // caching_sha2_password full auth: XOR(password + NUL, scramble) then RSA encrypt
        var plain = [UInt8](password.utf8)
        plain.append(0)
        for idx in plain.indices {
            plain[idx] ^= scramble[idx % max(scramble.count, 1)]
        }
        let pw = Data(plain)

        let algorithms: [SecKeyAlgorithm] = [
            .rsaEncryptionPKCS1,      // MySQL 8.0 default
            .rsaEncryptionOAEPSHA1,
            .rsaEncryptionOAEPSHA256
        ]
        for alg in algorithms {
            var err: Unmanaged<CFError>?
            if let cipher = SecKeyCreateEncryptedData(key, alg, pw as CFData, &err) {
                return Array(cipher as Data)
            }
        }
        throw MySQLError.authFailed("RSA 加密失败（请改用 TLS 或 mysql_native_password 账号）")
    }

    // MARK: - Query (sync)
    private func _query(_ sql: String) throws -> QueryResult {
        sequence = 0
        var payload = [UInt8(0x03)] // COM_QUERY
        payload += [UInt8](sql.utf8)
        try writePacket(payload)
        return try readQueryResult()
    }

    private func readQueryResult() throws -> QueryResult {
        let pkt = try readPacket()
        guard !pkt.isEmpty else { throw MySQLError.protocolError("空结果") }
        let first = pkt[0]
        if first == 0xFF {
            let (code, msg) = parseError(pkt)
            throw MySQLError.serverError(code: code, message: msg)
        }
        if first == 0x00 {
            let (affected, _) = readLenEncInt(pkt, 1)
            return .ok(affectedRows: Int(affected))
        }
        if first == 0xFE, pkt.count < 9 {
            return .ok(affectedRows: 0)
        }
        // Result set: first byte is column count
        let (colCount, _) = readLenEncInt(pkt, 0)
        var columns = [ColumnDef]()
        for _ in 0..<colCount {
            let colPkt = try readPacket()
            columns.append(parseColumn(colPkt))
        }
        let _ = try readPacket() // EOF after columns
        var rows = [[String?]]()
        while rows.count < maxRows {
            let rowPkt = try readPacket()
            if rowPkt.isEmpty { break }
            if rowPkt[0] == 0xFE, rowPkt.count < 9 { break } // EOF terminator
            var vals = [String?]()
            var i = 0
            for _ in 0..<colCount {
                let (len, isNull, ni) = readLenEncValue(rowPkt, i)
                if isNull {
                    vals.append(nil)
                    i = ni
                } else {
                    let end = min(ni + Int(len), rowPkt.count)
                    let bytes = Array(rowPkt[ni..<end])
                    vals.append(String(bytes: bytes, encoding: .utf8))
                    i = end
                }
            }
            rows.append(vals)
        }
        return .result(columns: columns, rows: rows)
    }

    private func parseColumn(_ pkt: [UInt8]) -> ColumnDef {
        var i = 0
        _ = readLenEncStr(pkt, &i) // catalog
        _ = readLenEncStr(pkt, &i) // schema
        _ = readLenEncStr(pkt, &i) // table
        _ = readLenEncStr(pkt, &i) // org_table
        let name = readLenEncStr(pkt, &i) ?? ""
        _ = readLenEncStr(pkt, &i) // org_name
        i += 1 // length of fixed fields (0x0C)
        i += 2 // charset
        i += 4 // column length
        guard i < pkt.count else { return ColumnDef(name: name, type: 0) }
        let typeByte = pkt[i]; i += 1
        i += 2 // flags
        i += 1 // decimals
        i += 2 // filler
        return ColumnDef(name: name, type: typeByte)
    }

    private func parseError(_ pkt: [UInt8]) -> (Int, String) {
        var i = 1
        let code = Int(pkt[i]) | Int(pkt[i + 1]) << 8; i += 2
        if i < pkt.count, pkt[i] == 0x23 { i += 1 + 5 } // '#' + sqlstate
        let msg = String(bytes: pkt[i...], encoding: .utf8) ?? "未知错误"
        return (code, msg)
    }

    // MARK: - Packet I/O (sync, blocking)
    private func readExactly(_ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var total = 0
        while total < n {
            let got = buf.withUnsafeMutableBytes { raw in
                inputStream?.read(raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: total),
                                  maxLength: n - total) ?? -1
            }
            if got < 0 { throw MySQLError.readError }
            if got == 0 { throw MySQLError.connectionClosed }
            total += got
        }
        return buf
    }

    private func readPacket() throws -> [UInt8] {
        var full = [UInt8]()
        while true {
            let header = try readExactly(4)
            let len = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            if len == 0xFFFFFF {
                full.append(contentsOf: try readExactly(len))
                continue
            } else if len == 0 {
                return full.isEmpty ? [] : full
            } else {
                full.append(contentsOf: try readExactly(len))
                return full
            }
        }
    }

    private func writeAll(_ data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBufferPointer { buf in
                outputStream?.write(buf.baseAddress!.advanced(by: offset), maxLength: data.count - offset) ?? -1
            }
            if sent <= 0 { throw MySQLError.writeError }
            offset += sent
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        let len = payload.count
        let header: [UInt8] = [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF), sequence]
        sequence = sequence &+ 1
        try writeAll(header)
        try writeAll(payload)
    }
}
