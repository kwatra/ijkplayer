//
//  ffmpeg_player.h
//  IJKMediaPlayer
//
//  Created by Nipun Kwatra on 11/9/16.
//  Copyright © 2016 bilibili. All rights reserved.
//

#ifndef ffmpeg_player_h
#define ffmpeg_player_h

#import <CoreMedia/CoreMedia.h>

struct FFVideoState;

@interface FFMpegPlayer : NSObject

@property (nonatomic) struct FFVideoState *videoState;

- (instancetype)initWithFilePath:(NSString *)filePath;
- (CMSampleBufferRef) readNextSampleBuffer;

@end

#endif /* ffmpeg_player_h */
