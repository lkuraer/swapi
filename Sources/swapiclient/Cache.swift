//
//  CacheableWithID.swift
//  swapiclient
//
//  Created by Kes on 08/04/25.
//

import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

// MARK: - Кэширование объектов модели

/// Протокол для объектов, которые можно кэшировать с идентификатором
public protocol CacheableWithID {
    var id: String? { get }
}

// Расширения для приведения моделей к кэшируемому интерфейсу
extension Components.Schemas.PersonResponse: CacheableWithID {
    public var id: String? {
        return self.result?.uid
    }
}

extension Components.Schemas.PlanetResponse: CacheableWithID {
    public var id: String? {
        return self.result?.uid
    }
}

extension Components.Schemas.StarshipResponse: CacheableWithID {
    public var id: String? {
        return self.result?.uid
    }
}

extension Components.Schemas.ListResponse: CacheableWithID {
    public var id: String? {
        // Для списков используем хэш от комбинации страницы и лимита
        return nil // Будет задаваться извне при кэшировании
    }
}

// MARK: - Сервис для кэширования данных

/// Протокол для сервиса кэширования
public protocol CacheService {
    /// Сохранить объект в кэш
    func save<T: Codable>(_ object: T, forKey key: String) throws
    
    /// Получить объект из кэша
    func get<T: Codable>(forKey key: String, as type: T.Type) throws -> T?
    
    /// Проверить наличие объекта в кэше
    func exists(forKey key: String) -> Bool
    
    /// Удалить объект из кэша
    func remove(forKey key: String) throws
    
    /// Очистить весь кэш
    func clear() throws
}

// MARK: - Реализация кэширования через файловую систему

/// Кэш-сервис, использующий файловую систему
public class FileSystemCacheService: CacheService {
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    
    /// Инициализация с указанием директории кэша
    public init(cacheName: String = "swapi-cache") throws {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent(cacheName, isDirectory: true)
        
        // Создаем директорию кэша, если её нет
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    /// Получить URL для ключа кэша
    private func fileURL(forKey key: String) -> URL {
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return cacheDirectory.appendingPathComponent("\(safeKey).json")
    }
    
    public func save<T: Codable>(_ object: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(object)
        let fileURL = self.fileURL(forKey: key)
        try data.write(to: fileURL, options: .atomic)
    }
    
    public func get<T: Codable>(forKey key: String, as type: T.Type) throws -> T? {
        let fileURL = self.fileURL(forKey: key)
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(type, from: data)
    }
    
    public func exists(forKey key: String) -> Bool {
        let fileURL = self.fileURL(forKey: key)
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    public func remove(forKey key: String) throws {
        let fileURL = self.fileURL(forKey: key)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
    
    public func clear() throws {
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }
}

// MARK: - Реализация кэширования через UserDefaults

/// Кэш-сервис, использующий UserDefaults
public class UserDefaultsCacheService: CacheService {
    private let defaults: UserDefaults
    private let keyPrefix: String
    
    /// Инициализация с указанием UserDefaults и префикса для ключей
    public init(defaults: UserDefaults = .standard, keyPrefix: String = "swapi_cache_") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }
    
    /// Формирование полного ключа с префиксом
    private func prefixedKey(_ key: String) -> String {
        return "\(keyPrefix)\(key)"
    }
    
    public func save<T: Codable>(_ object: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(object)
        defaults.set(data, forKey: prefixedKey(key))
    }
    
    public func get<T: Codable>(forKey key: String, as type: T.Type) throws -> T? {
        guard let data = defaults.data(forKey: prefixedKey(key)) else {
            return nil
        }
        
        return try JSONDecoder().decode(type, from: data)
    }
    
    public func exists(forKey key: String) -> Bool {
        return defaults.object(forKey: prefixedKey(key)) != nil
    }
    
    public func remove(forKey key: String) throws {
        defaults.removeObject(forKey: prefixedKey(key))
    }
    
    public func clear() throws {
        let allKeys = defaults.dictionaryRepresentation().keys
        
        for key in allKeys {
            if key.hasPrefix(keyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

// MARK: - Конфигурация кэширования

/// Конфигурация для кэшированного клиента
public struct CacheConfig {
    /// Время жизни кэша в секундах
    public let ttl: TimeInterval
    /// Сервис для кэширования
    public let cacheService: CacheService
    /// Включить/выключить кэширование
    public let isEnabled: Bool
    
    /// Инициализация конфигурации кэширования
    public init(ttl: TimeInterval = 3600, // 1 час по умолчанию
                cacheService: CacheService,
                isEnabled: Bool = true) {
        self.ttl = ttl
        self.cacheService = cacheService
        self.isEnabled = isEnabled
    }
}

// MARK: - Кэширование метаданных

/// Метаданные объекта в кэше
struct CacheMetadata: Codable {
    /// Время создания записи в кэше
    let timestamp: Date
    /// Ключ для метаданных (добавляется постфикс _metadata)
    static func key(for objectKey: String) -> String {
        return "\(objectKey)_metadata"
    }
}

// MARK: - Клиент API с кэшированием

/// Кэшированная обёртка над SWAPI клиентом
public final class CachedSWAPIClient: APIProtocol {
    /// Базовый клиент API
    private let baseClient: APIProtocol
    /// Конфигурация кэширования
    private let cacheConfig: CacheConfig
    
    /// Инициализация кэшированного клиента
    public init(baseClient: APIProtocol, cacheConfig: CacheConfig) {
        self.baseClient = baseClient
        self.cacheConfig = cacheConfig
    }
    
    /// Вспомогательный метод для сохранения объекта в кэш с метаданными
    private func cacheObject<T: Codable>(_ object: T, forKey key: String) throws {
        guard cacheConfig.isEnabled else { return }
        
        // Сохраняем объект
        try cacheConfig.cacheService.save(object, forKey: key)
        
        // Сохраняем метаданные
        let metadata = CacheMetadata(timestamp: Date())
        try cacheConfig.cacheService.save(metadata, forKey: CacheMetadata.key(for: key))
    }
    
    /// Вспомогательный метод для проверки актуальности кэша
    private func isCacheValid(forKey key: String) -> Bool {
        guard cacheConfig.isEnabled else { return false }
        
        // Проверяем наличие метаданных
        guard let metadata = try? cacheConfig.cacheService.get(
            forKey: CacheMetadata.key(for: key),
            as: CacheMetadata.self
        ) else {
            return false
        }
        
        // Проверяем время жизни кэша
        let currentTime = Date()
        let cacheAge = currentTime.timeIntervalSince(metadata.timestamp)
        return cacheAge <= cacheConfig.ttl
    }
    
    /// Получить объект из кэша, если он актуален
    private func getCachedObject<T: Codable>(forKey key: String, as type: T.Type) -> T? {
        guard cacheConfig.isEnabled && isCacheValid(forKey: key) else {
            return nil
        }
        
        return try? cacheConfig.cacheService.get(forKey: key, as: type)
    }
    
    /// Генерация ключа кэша для списков с параметрами
    private func listCacheKey(endpoint: String, page: Int?, limit: Int?) -> String {
        return "\(endpoint)_page\(page ?? 1)_limit\(limit ?? 10)"
    }
    
    /// Генерация ключа кэша для конкретного объекта
    private func detailCacheKey(endpoint: String, id: String) -> String {
        return "\(endpoint)_\(id)"
    }
    
    // MARK: - API Methods Implementation

    public func listPeople(_ input: Operations.ListPeople.Input) async throws -> Operations.ListPeople.Output {
        let cacheKey = listCacheKey(endpoint: "people", page: input.query.page, limit: input.query.limit)
        
        // Проверяем кэш
        if let cachedResponse = getCachedObject(
            forKey: cacheKey,
            as: Operations.ListPeople.Output.Ok.Body.JsonPayload.self
        ) {
            return .ok(.init(body: .json(cachedResponse)))
        }
        
        // Если в кэше нет или он устарел, делаем запрос
        let response = try await baseClient.listPeople(input)
        
        // Кэшируем результат
        if case .ok(let okResponse) = response,
           case .json(let data) = okResponse.body {
            try? cacheObject(data, forKey: cacheKey)
        }
        
        return response
    }
    
    public func getPerson(_ input: Operations.GetPerson.Input) async throws -> Operations.GetPerson.Output {
        let cacheKey = detailCacheKey(endpoint: "people", id: input.path.id)
        
        // Проверяем кэш
        if let cachedResponse = getCachedObject(
            forKey: cacheKey,
            as: Components.Schemas.PersonResponse.self
        ) {
            return .ok(.init(body: .json(cachedResponse)))
        }
        
        // Если в кэше нет или он устарел, делаем запрос
        let response = try await baseClient.getPerson(input)
        
        // Кэшируем результат
        if case .ok(let okResponse) = response,
           case .json(let data) = okResponse.body {
            try? cacheObject(data, forKey: cacheKey)
        }
        
        return response
    }
    
    public func listPlanets(_ input: Operations.ListPlanets.Input) async throws -> Operations.ListPlanets.Output {
        let cacheKey = listCacheKey(endpoint: "planets", page: input.query.page, limit: input.query.limit)
        
        // Проверяем кэш
        if let cachedResponse = getCachedObject(
            forKey: cacheKey,
            as: Components.Schemas.ListResponse.self
        ) {
            return .ok(.init(body: .json(cachedResponse)))
        }
        
        // Если в кэше нет или он устарел, делаем запрос
        let response = try await baseClient.listPlanets(input)
        
        // Кэшируем результат
        if case .ok(let okResponse) = response,
           case .json(let data) = okResponse.body {
            try? cacheObject(data, forKey: cacheKey)
        }
        
        return response
    }
    
    public func getPlanet(_ input: Operations.GetPlanet.Input) async throws -> Operations.GetPlanet.Output {
        let cacheKey = detailCacheKey(endpoint: "planets", id: input.path.id)
        
        // Проверяем кэш
        if let cachedResponse = getCachedObject(
            forKey: cacheKey,
            as: Components.Schemas.PlanetResponse.self
        ) {
            return .ok(.init(body: .json(cachedResponse)))
        }
        
        // Если в кэше нет или он устарел, делаем запрос
        let response = try await baseClient.getPlanet(input)
        
        // Кэшируем результат
        if case .ok(let okResponse) = response,
           case .json(let data) = okResponse.body {
            try? cacheObject(data, forKey: cacheKey)
        }
        
        return response
    }
    
    public func listStarships(_ input: Operations.ListStarships.Input) async throws -> Operations.ListStarships.Output {
        let cacheKey = listCacheKey(endpoint: "starships", page: input.query.page, limit: input.query.limit)
        
        // Проверяем кэш
        if let cachedResponse = getCachedObject(
            forKey: cacheKey,
            as: Components.Schemas.ListResponse.self
        ) {
            return .ok(.init(body: .json(cachedResponse)))
        }
        
        // Если в кэше нет или он устарел, делаем запрос
        let response = try await baseClient.listStarships(input)
        
        // Кэшируем результат
        if case .ok(let okResponse) = response,
           case .json(let data) = okResponse.body {
            try? cacheObject(data, forKey: cacheKey)
        }
        
        return response
    }
    
    public func getStarship(_ input: Operations.GetStarship.Input) async throws -> Operations.GetStarship.Output {
        let cacheKey = detailCacheKey(endpoint: "starships", id: input.path.id)
        
        // Проверяем кэш
        if let cachedResponse = getCachedObject(
            forKey: cacheKey,
            as: Components.Schemas.StarshipResponse.self
        ) {
            return .ok(.init(body: .json(cachedResponse)))
        }
        
        // Если в кэше нет или он устарел, делаем запрос
        let response = try await baseClient.getStarship(input)
        
        // Кэшируем результат
        if case .ok(let okResponse) = response,
           case .json(let data) = okResponse.body {
            try? cacheObject(data, forKey: cacheKey)
        }
        
        return response
    }
}

// MARK: - Factory для создания клиента

/// Фабрика для создания клиентов SWAPI с кэшированием
public enum SWAPIClientFactory {
    /// Создать стандартный клиент без кэширования
    public static func createStandardClient() throws -> APIProtocol {
        let serverURL = try Servers.Server1.url()
        let client = Client(serverURL: serverURL, transport: URLSessionTransport())
        return client
    }
    
    /// Создать клиент с файловым кэшированием
    public static func createFileSystemCachedClient(
        ttl: TimeInterval = 3600,
        cacheName: String = "swapi-cache",
        isEnabled: Bool = true
    ) throws -> APIProtocol {
        let baseClient = try createStandardClient()
        let cacheService = try FileSystemCacheService(cacheName: cacheName)
        
        let cacheConfig = CacheConfig(
            ttl: ttl,
            cacheService: cacheService,
            isEnabled: isEnabled
        )
        
        return CachedSWAPIClient(baseClient: baseClient, cacheConfig: cacheConfig)
    }
    
    /// Создать клиент с кэшированием в UserDefaults
    public static func createUserDefaultsCachedClient(
        ttl: TimeInterval = 3600,
        keyPrefix: String = "swapi_cache_",
        isEnabled: Bool = true
    ) throws -> APIProtocol {
        let baseClient = try createStandardClient()
        let cacheService = UserDefaultsCacheService(keyPrefix: keyPrefix)
        
        let cacheConfig = CacheConfig(
            ttl: ttl,
            cacheService: cacheService,
            isEnabled: isEnabled
        )
        
        return CachedSWAPIClient(baseClient: baseClient, cacheConfig: cacheConfig)
    }
}
