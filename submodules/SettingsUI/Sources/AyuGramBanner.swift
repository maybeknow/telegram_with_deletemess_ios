import Foundation
import UIKit

/// Кастомный баннер своего профиля (AyuGram): картинка лежит в `Documents/ayu-banner.png`,
/// поэтому её видно в приложении «Файлы», она не уходит в облако и переживает перезапуск.
public enum AyuGramBanner {
    private static var fileURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("ayu-banner.png")
    }

    public static var hasBanner: Bool {
        guard let fileURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    public static func load() -> UIImage? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return UIImage(data: data)
    }

    /// Сохраняет картинку, обрезая её под пропорции шапки профиля (широкая полоса), чтобы она не
    /// растягивалась в кашу. Возвращает `false`, если файл записать не удалось.
    @discardableResult
    public static func save(image: UIImage) -> Bool {
        guard let fileURL else {
            return false
        }
        let targetAspect: CGFloat = 1.6
        let cropped = self.cropped(image: image, aspect: targetAspect)
        guard let data = cropped.pngData() else {
            return false
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func clear() -> Bool {
        guard let fileURL else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    private static func cropped(image: UIImage, aspect: CGFloat) -> UIImage {
        guard let cgImage = image.cgImage else {
            return image
        }
        let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        guard size.width > 0.0, size.height > 0.0 else {
            return image
        }
        var rect = CGRect(origin: CGPoint(), size: size)
        let currentAspect = size.width / size.height
        if currentAspect > aspect {
            // шире нужного — режем по бокам
            let targetWidth = size.height * aspect
            rect.origin.x = (size.width - targetWidth) / 2.0
            rect.size.width = targetWidth
        } else if currentAspect < aspect {
            // выше нужного — режем сверху и снизу
            let targetHeight = size.width / aspect
            rect.origin.y = (size.height - targetHeight) / 2.0
            rect.size.height = targetHeight
        }
        guard let croppedCG = cgImage.cropping(to: rect) else {
            return image
        }
        return UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
    }
}
