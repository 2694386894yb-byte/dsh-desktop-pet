// 3D 形象本体：几何全部用代码搭（不依赖任何外部模型文件），动画逐帧算。
//
// 为什么不用 CAAnimation 编排：形象一直在动（呼吸、眨眼、发呆、干活、庆祝），
// 用 SCNSceneRendererDelegate 每帧算姿态最简单也最好调——状态切换只是换目标值，
// 当前值用指数平滑追上去，不会出现动画叠动画的抖动。
import AppKit
import SceneKit

final class AvatarRig: NSObject, SCNSceneRendererDelegate {

    /// 形象的心情。菜单栏那点像素里，心情靠「动法 + 发光颜色」区分，不靠文字。
    enum Mood: String {
        case idle        // 发呆：慢呼吸、偶尔眨眼、左右看
        case working     // 干活中：快抖、天线脉冲、轨道环转起来（琥珀色）
        case celebrate   // 出结果：跳一下 + 转一圈 + 星星（青绿色）
        case sleep       // 长时间没动静：闭眼、慢呼吸、光变暗
        case paused      // 暂停监听：安静待着

        var eyeColor: NSColor {
            switch self {
            // 奶蛙默认是绿眼睛；干活转琥珀、出结果转亮绿、打盹转暗蓝。
            case .idle: return NSColor(srgbRed: 0.30, green: 0.72, blue: 0.32, alpha: 1)
            case .working: return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.22, alpha: 1)
            case .celebrate: return NSColor(srgbRed: 0.40, green: 0.95, blue: 0.45, alpha: 1)
            case .sleep: return NSColor(srgbRed: 0.28, green: 0.45, blue: 0.52, alpha: 1)
            case .paused: return NSColor(srgbRed: 0.55, green: 0.60, blue: 0.60, alpha: 1)
            }
        }
    }

    // MARK: 场景骨架
    let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let root = SCNNode()
    private let headGroup = SCNNode()
    private let bodyGroup = SCNNode()
    private let faceGroup = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()
    private let mouth = SCNNode()
    /// 旧机器人天线的占位节点：奶蛙没有天线，保留空节点让取景与动画代码不必分叉。
    private let antennaBeam = SCNNode()
    private let ring = SCNNode()
    private let leftArm = SCNNode()
    private let rightArm = SCNNode()
    private var glowNodes: [SCNNode] = []   // 需要跟着心情换发光色的节点
    /// 状态装饰（轨道环、天线光柱）：不参与「相机取景」的包围盒计算。
    private var decorations: [SCNNode] = []
    private var particles: SCNParticleSystem?
    private let particleHolder = SCNNode()

    // MARK: 动画状态
    private(set) var mood: Mood = .idle
    private var lastTime: TimeInterval = 0
    private var blinkAt: TimeInterval = 0
    private var blinkStart: TimeInterval = -10
    private var nextLookAt: TimeInterval = 0
    private var lookTarget: CGFloat = 0
    private var celebrateStart: TimeInterval = -10
    private var burstUntil: TimeInterval = 0

    /// 当前姿态（平滑值）与目标姿态。
    private struct Pose {
        var bobAmp: CGFloat = 0.020
        var bobSpeed: Double = 1.7
        var breathe: CGFloat = 0.012
        var eyeOpen: CGFloat = 1.0
        var glow: CGFloat = 1.0
        var ringOpacity: CGFloat = 0.0
        var tiltForward: CGFloat = 0.0
        var yawSway: CGFloat = 0.13
        var headDrop: CGFloat = 0.0
    }
    private var current = Pose()
    private var target = Pose()

    /// 相机垂直视角（度）。小窗口里用窄视角，透视畸变小、更「玩具感」。
    private let fieldOfView: CGFloat = 30
    private var bodyLaughUntil: TimeInterval = 0
    /// 形象在窗口里占的比例（留边给粒子、天线光和来回摆动的轨道环）。
    /// 实测：0.80 时环会顶到窗口下沿被切掉（渲染像素 bbox 贴边），0.78 有 ~5pt 余量。
    private let fillRatio: CGFloat = 0.62

    override init() {
        var glow: [SCNNode] = []
        super.init()

        scene.rootNode.addChildNode(root)
        buildMaterialsAndParts(glowCollector: &glow)
        glowNodes = glow

        // 相机
        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.zNear = 0.01
        camera.zFar = 200
        camera.wantsHDR = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        addLights()
        buildParticles()
        applyMood(animated: false)
    }

    // MARK: - 建模

    private func material(_ color: NSColor, roughness: CGFloat = 0.45, specular: CGFloat = 0.55) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = NSColor(white: 1, alpha: specular)
        m.shininess = 0.6
        m.roughness.contents = roughness
        m.locksAmbientWithDiffuse = true
        return m
    }

    private func emissive(_ color: NSColor, intensity: CGFloat = 1.0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.multiply.contents = NSColor(white: intensity, alpha: 1)
        return m
    }

    private func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, chamfer: CGFloat, _ mat: SCNMaterial) -> SCNNode {
        let g = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
        g.materials = [mat]
        return SCNNode(geometry: g)
    }

    private func sphere(_ r: CGFloat, _ mat: SCNMaterial) -> SCNNode {
        let g = SCNSphere(radius: r)
        g.segmentCount = 32
        g.materials = [mat]
        return SCNNode(geometry: g)
    }

    private func capsule(_ r: CGFloat, _ h: CGFloat, _ mat: SCNMaterial) -> SCNNode {
        let g = SCNCapsule(capRadius: r, height: h)
        g.materials = [mat]
        return SCNNode(geometry: g)
    }

    private func buildMaterialsAndParts(glowCollector: inout [SCNNode]) {
        // 配色照着「奶蛙」来：黄色果冻皮肤 + 大块奶油肚皮 + 深橄榄褐色手脚，
        // 眼睛是凸起的圆眼、眼白泛绿、瞳孔只有一个小黑点。
        let skin = material(NSColor(srgbRed: 1.00, green: 0.76, blue: 0.16, alpha: 1), roughness: 0.42, specular: 0.55)
        let bellyMat = material(NSColor(srgbRed: 1.00, green: 0.93, blue: 0.78, alpha: 1), roughness: 0.50, specular: 0.32)
        let limbMat = material(NSColor(srgbRed: 0.36, green: 0.31, blue: 0.18, alpha: 1), roughness: 0.46, specular: 0.30)
        let scleraMat = material(NSColor(srgbRed: 0.90, green: 0.94, blue: 0.80, alpha: 1), roughness: 0.24, specular: 0.7)
        let irisMat = material(mood.eyeColor, roughness: 0.20, specular: 0.8)
        let pupilMat = material(NSColor(srgbRed: 0.05, green: 0.05, blue: 0.04, alpha: 1), roughness: 0.12, specular: 0.9)
        let mouthMat = material(NSColor(srgbRed: 0.26, green: 0.13, blue: 0.11, alpha: 1), roughness: 0.35)
        let glintMat = emissive(NSColor(white: 1, alpha: 1))

        // —— 梨形身体：下腹最鼓，往上收，头和身体连成一体没有脖子。
        let lowerBody = sphere(0.60, skin)
        lowerBody.scale = SCNVector3(1.00, 0.96, 0.90)
        lowerBody.position = SCNVector3(0, -0.44, 0)
        bodyGroup.addChildNode(lowerBody)

        let upperBody = sphere(0.50, skin)
        upperBody.scale = SCNVector3(0.94, 1.02, 0.86)
        upperBody.position = SCNVector3(0, 0.02, 0)
        bodyGroup.addChildNode(upperBody)

        // 大块奶油色肚皮：必须**凸出**身体表面才看得见整块，
        // 否则会被身体包住、只在边缘露出一圈月牙（第一版渲染出来像个笑脸）。
        // 身体正面在 y=-0.38 处约 z=0.54，所以肚皮前表面放到 0.57。
        let belly = sphere(0.46, bellyMat)
        belly.scale = SCNVector3(0.88, 1.00, 0.33)
        belly.position = SCNVector3(0, -0.38, 0.42)
        bodyGroup.addChildNode(belly)

        // —— 手脚：深橄榄褐色、比身体修长，默认就摆成「双手捂着肚子」。
        // 手的落点按几何反解：从肩点 (±0.50, 0.10, 0.06) 够到肚皮上的 (±0.20, -0.30, 0.58)，
        // 需要臂长 0.72、绕 x 转 -0.91、绕 z 转 ∓0.43（SceneKit 先转 z 再转 x）。
        for (sx, holder) in [(CGFloat(-1), leftArm), (CGFloat(1), rightArm)] {
            holder.position = SCNVector3(sx * 0.50, 0.10, 0.06)
            let arm = capsule(0.085, 0.56, skin)
            arm.position = SCNVector3(0, -0.28, 0)
            holder.addChildNode(arm)
            let hand = sphere(0.125, limbMat)
            hand.scale = SCNVector3(1.0, 0.92, 1.10)
            hand.position = SCNVector3(0, -0.72, 0)
            holder.addChildNode(hand)
            bodyGroup.addChildNode(holder)
        }

        for sx in [CGFloat(-1), CGFloat(1)] {
            let leg = capsule(0.070, 0.14, limbMat)
            leg.position = SCNVector3(sx * 0.24, -0.98, 0.02)
            bodyGroup.addChildNode(leg)
            let foot = sphere(0.130, limbMat)
            foot.scale = SCNVector3(1.30, 0.45, 1.15)
            foot.position = SCNVector3(sx * 0.26, -1.06, 0.10)
            bodyGroup.addChildNode(foot)
        }

        // 干活时的金色光环（比机器人的轨道环更柔和，贴着肚子转）。
        let torus = SCNTorus(ringRadius: 0.78, pipeRadius: 0.016)
        torus.ringSegmentCount = 64
        torus.materials = [emissive(NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1), intensity: 0.85)]
        ring.geometry = torus
        ring.position = SCNVector3(0, -0.38, 0)
        ring.eulerAngles = SCNVector3(CGFloat.pi / 2 - 0.38, 0, 0.20)
        ring.opacity = 0
        bodyGroup.addChildNode(ring)
        glowCollector.append(ring)

        root.addChildNode(bodyGroup)

        // —— 头：圆顶，直接长在身体上（headGroup 的原点就是头颈交界）。
        let skull = sphere(0.46, skin)
        skull.scale = SCNVector3(0.96, 1.00, 0.92)
        skull.position = SCNVector3(0, 0.10, 0)
        headGroup.addChildNode(skull)

        // 凸起的圆眼：泛绿眼白 + 绿色虹膜 + 小黑点瞳孔 + 高光。
        for (sx, node) in [(CGFloat(-1), leftEye), (CGFloat(1), rightEye)] {
            let sclera = sphere(0.195, scleraMat)
            sclera.scale = SCNVector3(1.0, 1.06, 0.86)
            node.addChildNode(sclera)
            // 虹膜别太大：奶蛙的标志是「眼白泛绿 + 小黑点瞳孔」。
            let iris = sphere(0.088, irisMat)
            iris.scale = SCNVector3(1.0, 1.0, 0.55)
            iris.position = SCNVector3(0, -0.012, 0.108)
            node.addChildNode(iris)
            let pupil = sphere(0.040, pupilMat)
            pupil.scale = SCNVector3(1.0, 1.0, 0.55)
            pupil.position = SCNVector3(0, -0.016, 0.152)
            node.addChildNode(pupil)
            let glint = sphere(0.024, glintMat)
            glint.position = SCNVector3(-0.034, 0.044, 0.176)
            node.addChildNode(glint)
            node.position = SCNVector3(sx * 0.185, 0.21, 0.28)
            headGroup.addChildNode(node)
            glowCollector.append(iris)
        }

        // 小嘴：平时是一条小缝，狂笑时会张开。
        let mouthGeo = SCNSphere(radius: 0.075)
        mouthGeo.segmentCount = 24
        mouthGeo.materials = [mouthMat]
        mouth.geometry = mouthGeo
        mouth.scale = SCNVector3(1.25, 0.45, 0.45)
        mouth.position = SCNVector3(0, 0.01, 0.42)
        headGroup.addChildNode(mouth)

        headGroup.position = SCNVector3(0, 0.42, 0)
        root.addChildNode(headGroup)

        // 庆祝粒子从胸前发出（不再是头顶天线）。
        root.addChildNode(particleHolder)
        particleHolder.position = SCNVector3(0, 0.30, 0)

        // 状态装饰不参与取景计算。
        decorations = [ring, antennaBeam]
    }

    private func addLights() {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 1, alpha: 1)
        ambient.intensity = 380
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 640
        key.color = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.85, 0.55, 0.15)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 260
        fill.color = NSColor(srgbRed: 0.65, green: 0.82, blue: 1.0, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(-1.5, -0.2, 1.8)
        scene.rootNode.addChildNode(fillNode)

        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 520
        rim.color = NSColor(srgbRed: 0.55, green: 0.95, blue: 1.0, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(0.9, 1.2, -2.2)
        scene.rootNode.addChildNode(rimNode)
    }

    private func buildParticles() {
        let system = SCNParticleSystem()
        system.birthRate = 0
        system.particleLifeSpan = 0.75
        system.particleLifeSpanVariation = 0.2
        // 速度压到 1.15：窗口只有 38×45pt，星散太大就会被边缘切掉（实测 1.9 时左右贴边）。
        system.particleVelocity = 1.15
        system.particleVelocityVariation = 0.5
        system.spreadingAngle = 180
        system.particleSize = 0.05
        system.particleSizeVariation = 0.025
        system.particleColor = NSColor(srgbRed: 0.6, green: 1.0, blue: 0.85, alpha: 1)
        system.particleColorVariation = SCNVector4(0.05, 0.15, 0.15, 0)
        system.blendMode = .additive
        system.isAffectedByGravity = false
        system.emitterShape = SCNSphere(radius: 0.18)
        system.birthLocation = .volume
        system.particleImage = AvatarRig.sparkImage()
        system.loops = true
        system.isLocal = false
        particles = system
        particleHolder.addParticleSystem(system)
    }

    /// 粒子的贴图：中心亮点 + 径向渐变，省得外挂图片文件。
    static func sparkImage(size: CGFloat = 48) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let center = CGPoint(x: size / 2, y: size / 2)
            let colors = [NSColor(white: 1, alpha: 1).cgColor,
                          NSColor(white: 1, alpha: 0.55).cgColor,
                          NSColor(white: 1, alpha: 0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 0.35, 1]) {
                ctx.drawRadialGradient(gradient,
                                       startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: size / 2,
                                       options: [])
            }
        }
        image.unlockFocus()
        return image
    }

    // MARK: - 状态

    func setMood(_ new: Mood) {
        guard new != mood else { return }
        mood = new
        applyMood(animated: true)
    }

    private func applyMood(animated: Bool) {
        var p = Pose()
        switch mood {
        case .idle:
            p.bobAmp = 0.022; p.bobSpeed = 1.6; p.breathe = 0.014
            p.eyeOpen = 1.0; p.glow = 1.0; p.ringOpacity = 0
        case .working:
            p.bobAmp = 0.013; p.bobSpeed = 5.6; p.breathe = 0.020
            p.eyeOpen = 0.62; p.glow = 1.5; p.ringOpacity = 0.95
            p.tiltForward = 0.07
        case .celebrate:
            p.bobAmp = 0.030; p.bobSpeed = 3.2; p.breathe = 0.030
            p.eyeOpen = 1.25; p.glow = 2.0; p.ringOpacity = 0.0
        case .sleep:
            p.bobAmp = 0.030; p.bobSpeed = 0.65; p.breathe = 0.018
            p.eyeOpen = 0.04; p.glow = 0.55; p.ringOpacity = 0
            p.headDrop = 0.14; p.yawSway = 0.04
        case .paused:
            p.bobAmp = 0.012; p.bobSpeed = 1.0; p.breathe = 0.006
            p.eyeOpen = 0.55; p.glow = 0.5; p.ringOpacity = 0
        }
        target = p
        for node in glowNodes {
            node.geometry?.firstMaterial?.emission.contents = mood.eyeColor
            node.geometry?.firstMaterial?.diffuse.contents = mood.eyeColor
        }
        if !animated {
            current = p
        }
    }

    /// 出结果：先弹一下，然后抱着肚子狂笑（奶蛙的招牌动作）。
    func celebrate() {
        let now = CACurrentMediaTime()
        celebrateStart = now
        bodyLaughUntil = now + 3.6
        setMood(.celebrate)
        burstUntil = now + 0.20
        particles?.birthRate = 1100
        particles?.reset()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
            guard let self else { return }
            if self.mood == .celebrate { self.setMood(.idle) }
        }
    }

    /// 被点一下：短促地笑两秒——奶蛙「点一下就狂笑」。
    func laughBriefly() {
        let now = CACurrentMediaTime()
        bodyLaughUntil = now + 1.8
        setMood(.celebrate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self else { return }
            if self.mood == .celebrate { self.setMood(.idle) }
        }
    }

    // MARK: - 逐帧动画

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 30.0 : min(max(time - lastTime, 0), 0.25)
        lastTime = time

        // 1) 姿态平滑靠拢目标（指数衰减，和帧率无关）
        let k = CGFloat(1 - exp(-dt * 7.0))
        current.bobAmp += (target.bobAmp - current.bobAmp) * k
        current.bobSpeed += (target.bobSpeed - current.bobSpeed) * Double(k)
        current.breathe += (target.breathe - current.breathe) * k
        current.eyeOpen += (target.eyeOpen - current.eyeOpen) * k
        current.glow += (target.glow - current.glow) * k
        current.ringOpacity += (target.ringOpacity - current.ringOpacity) * k
        current.tiltForward += (target.tiltForward - current.tiltForward) * k
        current.yawSway += (target.yawSway - current.yawSway) * k
        current.headDrop += (target.headDrop - current.headDrop) * k

        // 2) 眨眼：每隔 2.5~6 秒一次
        if blinkAt == 0 { blinkAt = time + 2.0 }
        if time >= blinkAt && time - blinkStart > 0.6 {
            blinkStart = time
            blinkAt = time + Double.random(in: 2.5...6.0)
        }
        var blink: CGFloat = 0
        let bt = time - blinkStart
        if bt >= 0 && bt < 0.15 {
            blink = CGFloat(sin(Double.pi * (bt / 0.15)))
        }

        // 3) 发呆时偶尔左右看
        if time >= nextLookAt {
            nextLookAt = time + Double.random(in: 2.0...5.0)
            lookTarget = CGFloat.random(in: -1...1)
        }
        let lookYaw = current.yawSway * lookTarget

        // 4) 庆祝：先弹一下，紧接着「捧腹大笑」
        var jump: CGFloat = 0
        var stretch: CGFloat = 1
        var nod: CGFloat = 0
        let ct = time - celebrateStart
        // 笑声包络：0.25 秒起势，收尾 0.6 秒淡出。
        var laughEnv: CGFloat = 0
        let remaining = bodyLaughUntil - time
        if remaining > 0 && ct >= 0 {
            laughEnv = min(1, CGFloat(ct / 0.25)) * min(1, CGFloat(remaining / 0.6))
        }
        let laughPulse = laughEnv * abs(sin(time * 16))         // 高频抖
        let laughHeave = laughEnv * (0.5 + 0.5 * sin(time * 7)) // 低频起伏
        if ct >= 0 && ct < 0.55 {
            let p = CGFloat(ct / 0.55)
            let hop = sin(.pi * min(p, 1))
            jump = hop * 0.12
            stretch = 1 + hop * 0.09
            nod = hop * 0.10
        }
        if time > burstUntil && (particles?.birthRate ?? 0) > 0 {
            particles?.birthRate = 0
        }

        // 5) 落到节点上
        let bob = CGFloat(sin(time * current.bobSpeed)) * current.bobAmp
        // 笑到发抖：整个人左右晃 + 上下颤。
        let shakeX = CGFloat(sin(time * 26)) * 0.055 * laughEnv
        let shakeY = CGFloat(sin(time * 21)) * 0.022 * laughEnv
        root.position = SCNVector3(shakeX * 0.35, bob + jump + shakeY, 0)
        root.eulerAngles = SCNVector3(0.16 * laughHeave, lookYaw, shakeX)
        // 体积守恒的拉伸：变高就变瘦，看着像有弹性而不是单纯放大。
        root.scale = SCNVector3(1 / sqrt(stretch), stretch, 1 / sqrt(stretch))

        let breathe = 1 + CGFloat(sin(time * current.bobSpeed * 0.9)) * current.breathe
        // 肚子一鼓一鼓：笑的时候横向撑开、纵向压扁。
        let bellyPuff = 1 + laughPulse * 0.075
        bodyGroup.scale = SCNVector3(breathe * bellyPuff,
                                     (1 + (breathe - 1) * 1.6) * (1 - laughPulse * 0.055),
                                     breathe * bellyPuff)
        // 低头弯腰笑，头跟着笑声点。
        headGroup.position = SCNVector3(0, 0.42 - current.headDrop - laughEnv * 0.10 - laughPulse * 0.03, 0)
        headGroup.eulerAngles = SCNVector3(current.tiltForward + current.headDrop * 0.6 + nod
                                           + laughPulse * 0.16,
                                           -lookYaw * 0.35,
                                           CGFloat(sin(time * 19)) * 0.05 * laughEnv)
        // 两只手按在肚子上，笑的时候来回揉。
        let rub = laughPulse * 0.14
        leftArm.eulerAngles = SCNVector3(-0.91, 0, 0.43 + rub)
        rightArm.eulerAngles = SCNVector3(-0.91, 0, -0.43 - rub)

        // 笑到眯眼：眼睛压成一条缝；嘴张开大笑。
        let eyeScale = max(current.eyeOpen * (1 - blink * 0.92) * (1 - laughEnv * 0.72), 0.04)
        leftEye.scale = SCNVector3(1, eyeScale, 1)
        rightEye.scale = SCNVector3(1, eyeScale, 1)
        mouth.scale = SCNVector3(1.25 + laughEnv * 0.55,
                                 0.45 + laughHeave * 1.15 + laughPulse * 0.35,
                                 0.45 + laughEnv * 0.30)

        // 发光强度：整体亮度 × 干活动脉
        let pulse = mood == .working ? (0.75 + 0.25 * CGFloat(sin(time * 7))) : 1.0
        let g = current.glow * pulse
        for node in glowNodes {
            node.geometry?.firstMaterial?.multiply.contents = NSColor(white: min(g, 2), alpha: 1)
        }

        // 干活时身体快速小幅发抖（奶蛙没有天线，靠抖动 + 光环表示在忙）。
        if mood == .working && laughEnv == 0 {
            let tremble = CGFloat(sin(time * 34)) * 0.010
            let tremble2 = CGFloat(cos(time * 27)) * 0.012
            root.position = SCNVector3(root.position.x + tremble2, root.position.y + tremble, 0)
            root.eulerAngles = SCNVector3(root.eulerAngles.x, root.eulerAngles.y, tremble2 * 1.6)
        }

        // 金色光环
        ring.opacity = current.ringOpacity
        let ringSpin = (mood == .working ? time * 2.4 : time * 0.6).truncatingRemainder(dividingBy: 2 * Double.pi)
        ring.eulerAngles = SCNVector3(CGFloat.pi / 2 - 0.38, CGFloat(ringSpin), 0.20)
    }

    private func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }

    // MARK: - 相机与视图

    /// 形象在世界坐标里的包围盒。
    ///
    /// 不能用 `root.boundingBox`：对没有几何体的节点它并不可靠。这里自己递归遍历几何体，
    /// 把八个角变换到世界坐标求并集。
    ///
    /// `includeDecorations: false` 会跳过轨道环和天线光柱——它们是「状态装饰」，
    /// 张得比身体大得多（环半径 0.63 vs 身体半宽 0.53）。实测算进去会让相机退太远，
    /// 身体只占窗口 62%；排掉之后身体占 ~77%，而环依然在画面内。
    func modelBounds(includeDecorations: Bool = true) -> (min: SCNVector3, max: SCNVector3) {
        var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude)
        var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude)
        var found = false

        func walk(_ node: SCNNode) {
            if !includeDecorations && decorations.contains(where: { $0 === node }) { return }
            if let geometry = node.geometry {
                let (bmin, bmax) = geometry.boundingBox
                for xi in 0..<2 {
                    for yi in 0..<2 {
                        for zi in 0..<2 {
                            let corner = SCNVector3(xi == 0 ? bmin.x : bmax.x,
                                                    yi == 0 ? bmin.y : bmax.y,
                                                    zi == 0 ? bmin.z : bmax.z)
                            let world = node.convertPosition(corner, to: nil)
                            lo = SCNVector3(min(lo.x, world.x), min(lo.y, world.y), min(lo.z, world.z))
                            hi = SCNVector3(max(hi.x, world.x), max(hi.y, world.y), max(hi.z, world.z))
                            found = true
                        }
                    }
                }
            }
            for child in node.childNodes { walk(child) }
        }
        walk(root)
        guard found else { return (SCNVector3(-1, -1, -1), SCNVector3(1, 1, 1)) }
        return (lo, hi)
    }

    /// 按窗口尺寸把相机摆到「形象正好占满 fillRatio」的位置。
    func fitCamera(viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        let (lo, hi) = modelBounds(includeDecorations: false)
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let halfH = max(CGFloat(hi.y - lo.y) / 2, 0.1)
        let halfW = max(CGFloat(max(hi.x - lo.x, hi.z - lo.z)) / 2, 0.1)
        let tanY = tan(fieldOfView * .pi / 180 / 2)
        let aspect = viewSize.width / viewSize.height
        let tanX = tanY * aspect
        let distance = max(halfH / tanY, halfW / tanX) / fillRatio * 1.04
        cameraNode.position = SCNVector3(center.x, center.y + 0.05, center.z + distance)
        cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        // 视线略微抬高 → 形象在画面里稍微靠下，头顶给天线和星星留出余量。
        cameraNode.look(at: SCNVector3(center.x, center.y + 0.06, center.z))
        if let cam = cameraNode.camera {
            cam.zNear = max(0.01, Double(distance) * 0.05)
            cam.zFar = Double(distance) * 10
        }
    }

    /// 相机与包围盒的实测数据（自检用）。
    func debugGeometry() -> (lo: SCNVector3, hi: SCNVector3, distance: CGFloat, fillRatio: CGFloat) {
        let (lo, hi) = modelBounds(includeDecorations: false)
        return (lo, hi, cameraNode.position.z, fillRatio)
    }

    /// 把一个已经存在的 SCNView 配好（透明背景、持续渲染、30fps、挂上逐帧回调）。
    func configure(_ view: SCNView, frame: NSRect) {
        view.frame = frame
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling4X
        view.scene = scene
        view.pointOfView = cameraNode
        view.backgroundColor = .clear
        // 注意：SCNView.isOpaque 是只读的（由场景背景决定），透明靠 backgroundColor + 图层。
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.rendersContinuously = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.delegate = self
        fitCamera(viewSize: frame.size)
    }
}
