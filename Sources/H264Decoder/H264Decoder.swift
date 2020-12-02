//
//  H264Decoder.swift
//
//
//  Created by UnpxreTW on 2020/11/30.
//  Copyright © 2020 UnpxreTW. All rights reserved.
//

import AVFoundation

private typealias Byte = UInt8
private typealias VideoPacket = Array<Byte>

public struct H264Decoder {
    
    // MARK: Private Variable

    private let startCode: Data = .init([0x00, 0x00, 0x00, 0x01])
    private var sendNewFrame: ((CMSampleBuffer) -> Void)?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: VideoPacket?
    private var pps: VideoPacket?

    // MARK: Public Function
    
    public mutating func qnqueue(_ data: Data) {
        var data = data
        while var packet = findPacket(from: &data) {
            receivedRawVideoFrame(in: &packet)
        }
    }

    public mutating func setHandler(_ handler: @escaping ((CMSampleBuffer) -> Void)) {
        self.sendNewFrame = handler
    }

    // MARK: Private Function

    private func findPacket(from data: inout Data) -> VideoPacket? {
        var packet: VideoPacket?
        guard data.count > startCode.count else { return nil }
        if let rear = data.range(of: startCode, in: startCode.count ..< data.count)?.lowerBound {
            packet = Array(data.subdata(in: 0 ..< rear))
            data.removeSubrange(0 ..< rear)
        } else {
            packet = Array(data)
            data.removeAll()
        }
        return packet
    }

    /// note: 對於 VideoToolBox 來說前四個位元並不是 StartCode 而應該為資料長度，所以需要手動填入。
    private mutating func receivedRawVideoFrame(in videoPacket: inout VideoPacket) {
        guard videoPacket.count > 4 else { return }
        let start = 4
        var length = CFSwapInt32HostToBig(UInt32(videoPacket.count - start))
        memcpy(&videoPacket, &length, start)
        let nalType = videoPacket[start] & 0x1F
        switch nalType {
        case 0x05:
            guard createFormatDescription() else { return }
            decode(videoPacket)
        case 0x07:
            sps = Array(videoPacket[start ..< videoPacket.count])
        case 0x08:
            pps = Array(videoPacket[start ..< videoPacket.count])
        default:
            decode(videoPacket)
        }
    }

    // FIXME: 強制解開 UnsafeBufferPointer.baseAddress 看起來不夠安全，
    //        雖然當 count > 0 時 baseAddress 不會是 nil 的。
    private mutating func createFormatDescription() -> Bool {
        if formatDescription != nil { formatDescription = nil }
        guard let sps = sps, let pps = pps else { return false }
        let parameterSizes = [sps.count, pps.count]
        let status = sps.withUnsafeBufferPointer { spsPointer -> OSStatus in
            pps.withUnsafeBufferPointer { ppsPointer in
                let parameterSet = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                return parameterSet.withUnsafeBufferPointer { parameterSetPointer in
                    parameterSizes.withUnsafeBufferPointer { parameterSizesPointer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: parameterSetPointer.baseAddress!,
                            parameterSetSizes: parameterSizesPointer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }
        return status == noErr
    }

    private func decode(_ packet: VideoPacket) {
        var _packet = packet
        var blockBuffer: CMBlockBuffer?
        var status = _packet.withUnsafeMutableBytes { pointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: pointer.baseAddress,
                blockLength: packet.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: packet.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == noErr else { return }
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [packet.count]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer)
        guard status == kCMBlockBufferNoErr, let buffer = sampleBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)
        guard let _attachments = attachments else { return }
        CFDictionarySetValue(
            unsafeBitCast(CFArrayGetValueAtIndex(_attachments, 0), to: CFMutableDictionary.self),
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        sendNewFrame?(buffer)
    }
}