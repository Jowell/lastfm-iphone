/* LastFMService.m - AudioScrobbler webservice proxy
 * Copyright (C) 2008 Sam Steele
 *
 * This file is part of MobileLastFM.
 *
 * MobileLastFM is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2
 * as published by the Free Software Foundation.
 *
 * MobileLastFM is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA
 */

#import <Foundation/NSCharacterSet.h>
#import "LastFMService.h"
#import "NSString+MD5.h"
#import "NSString+URLEscaped.h"
#import "MobileLastFMApplicationDelegate.h"
#include "version.h"

@interface CXMLNode (objectAtXPath)
-(id)objectAtXPath:(NSString *)XPath;
@end

@implementation CXMLNode (objectAtXPath)
-(id)objectAtXPath:(NSString *)XPath {
	NSError *err;
	NSArray *nodes = [self nodesForXPath:XPath error:&err];
	if([nodes count]) {
		NSMutableArray *strings = [[NSMutableArray alloc] init];
		for(CXMLNode *node in nodes) {
			if([node stringValue])
				[strings addObject:[[node stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
		}
		if([strings count] == 1) {
			NSString *output = [NSString stringWithString:[strings objectAtIndex:0]];
			[strings release];
			return output;
		} else if([strings count] > 1) {
			return [strings autorelease];
		} else {
			[strings release];
			return @"";
		}
	} else {
		return @"";
	}
}
@end

BOOL shouldUseCache(NSString *file, double seconds) {
	NSDate *age = [[[NSFileManager defaultManager] fileAttributesAtPath:file traverseLink:YES] objectForKey:NSFileModificationDate];
	if(age==nil) return NO;
	if(([age timeIntervalSinceNow] * -1) > seconds) {
		[[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
		return NO;
	} else
		return YES;
}

@implementation LastFMService
@synthesize session;
@synthesize error;

+ (LastFMService *)sharedInstance {
  static LastFMService *sharedInstance;
	
  @synchronized(self) {
    if(!sharedInstance)
      sharedInstance = [[LastFMService alloc] init];
		
    return sharedInstance;
  }
	return nil;
}
- (NSArray *)_doMethod:(NSString *)method maxCacheAge:(double)seconds XPath:(NSString *)XPath withParams:(NSArray *)params {
	NSData *theResponseData;
	NSURLResponse *theResponse = NULL;
	NSError *theError = NULL;

	[error release];
	error = nil;
	
	NSArray *sortedParams = [[params arrayByAddingObjectsFromArray:[NSArray arrayWithObjects:[NSString stringWithFormat:@"method=%@",method],session?[NSString stringWithFormat:@"sk=%@",session]:nil,nil]] sortedArrayUsingSelector:@selector(compare:)];
	NSMutableString *signature = [[NSMutableString alloc] init];
	for(NSString *param in sortedParams) {
		[signature appendString:[[param stringByReplacingOccurrencesOfString:@"=" withString:@""] unURLEscape]];
	}
	[signature appendString:[NSString stringWithFormat:@"%s", API_SECRET]];
	if(seconds && shouldUseCache(CACHE_FILE([signature md5sum]),seconds)) {
		theResponseData = [NSData dataWithContentsOfFile:CACHE_FILE([signature md5sum])];
	} else {
		NSMutableURLRequest *theRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%s", API_URL]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:[((MobileLastFMApplicationDelegate *)[UIApplication sharedApplication].delegate) hasWiFiConnection]?40:60];
		[theRequest setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];
		[theRequest setHTTPMethod:@"POST"];
		[theRequest setHTTPBody:[[NSString stringWithFormat:@"%@&api_sig=%@", [sortedParams componentsJoinedByString:@"&"], [signature md5sum]] dataUsingEncoding:NSUTF8StringEncoding]];
		
		theResponseData = [NSURLConnection sendSynchronousRequest:theRequest returningResponse:&theResponse error:&theError];
		if(seconds)
			[theResponseData writeToFile:CACHE_FILE([signature md5sum]) atomically:YES];
	}
	[signature release];
	[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
	
	if(theError) {
		error = [theError retain];
		return nil;
	}
	CXMLDocument *d = [[[CXMLDocument alloc] initWithData:theResponseData options:0 error:&theError] autorelease];
	if(theError) {
		error = [theError retain];
		return nil;
	}
	
	NSArray *output = [[d rootElement] nodesForXPath:XPath error:&theError];
	if(![[[d rootElement] objectAtXPath:@"./@status"] isEqualToString:@"ok"]) {
		error = [[NSError alloc] initWithDomain:LastFMServiceErrorDomain
																			 code:[[[d rootElement] objectAtXPath:@"./error/@code"] intValue]
																	 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[[d rootElement] objectAtXPath:@"./error"],NSLocalizedDescriptionKey,nil]];		
		return nil;
	}
	return output;
}
- (NSArray *)doMethod:(NSString *)method maxCacheAge:(double)seconds XPath:(NSString *)XPath withParameters:(NSString *)firstParam, ... {
	NSMutableArray *params = [[NSMutableArray alloc] init];
	NSArray *output = nil;
	id eachParam;
	va_list argumentList;
	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	
	if(firstParam) {
		[params addObject: firstParam];
		va_start(argumentList, firstParam);
		while (eachParam = va_arg(argumentList, id)) {
			[params addObject: eachParam];
		}
		va_end(argumentList);
  }
	
	[params addObject:[NSString stringWithFormat:@"api_key=%s", API_KEY]];
	
	output = [self _doMethod:method maxCacheAge:seconds XPath:XPath withParams:params];
	[params release];
	return output;
}
- (NSDictionary *)_convertNode:(CXMLNode *)node toDictionaryWithXPaths:(NSArray *)XPaths forKeys:(NSArray *)keys {
	NSDictionary *map = [NSDictionary dictionaryWithObjects:XPaths forKeys:keys];
	NSMutableArray *objects = [[NSMutableArray alloc] init];
	
	for(NSString *key in keys) {
		NSString *xpath = [map objectForKey:key];
		[objects addObject:[node objectAtXPath:xpath]];
	}
	
	NSDictionary *output = [NSDictionary dictionaryWithObjects:objects forKeys:keys];
	[objects release];
	return output;
}
- (NSArray *)_convertNodes:(NSArray *)nodes toArrayWithXPaths:(NSArray *)XPaths forKeys:(NSArray *)keys {
	NSMutableArray *output = nil;
	if([nodes count]) {
		output = [[[NSMutableArray alloc] init] autorelease];
		for(CXMLNode *node in nodes) {
			[output addObject:[self _convertNode:node 
										toDictionaryWithXPaths:XPaths
																	 forKeys:keys]];
		}
	}
	return output;
}

#pragma mark Artist methods

- (NSDictionary *)metadataForArtist:(NSString *)artist inLanguage:(NSString *)lang {
	NSDictionary *metadata = nil;
	NSArray *nodes = [self doMethod:@"artist.getInfo" maxCacheAge:7*DAYS XPath:@"./artist" withParameters:[NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
	if([nodes count]) {
		CXMLNode *node = [nodes objectAtIndex:0];
		metadata = [self _convertNode:node
					 toDictionaryWithXPaths:[NSArray arrayWithObjects:@"./name", @"./image[@size=\"large\"]", @"./bio/content", nil]
													forKeys:[NSArray arrayWithObjects:@"name", @"image", @"bio", nil]];
	}
	return metadata;
}
- (NSArray *)eventsForArtist:(NSString *)artist {
	NSArray *nodes = [self doMethod:@"artist.getEvents" maxCacheAge:1*DAYS XPath:@"./events/event" withParameters:[NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./id", @"./artists/headliner", @"./artists/artist", @"./title", @"./description", @"./venue/name", @"./venue/location/street", @"./venue/location/city", @"./venue/location/postalcode", @"./venue/location/country", @"./startDate", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"id", @"headliner", @"artists", @"title", @"description", @"venue", @"street", @"city", @"postalcode", @"country", @"startDate", @"image", nil]];
}
- (NSArray *)artistsSimilarTo:(NSString *)artist {
	NSArray *nodes = [self doMethod:@"artist.getSimilar" maxCacheAge:7*DAYS XPath:@"./similarartists/artist" withParameters:[NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./match", @"./image[@size=\"medium\"]", @"./streamable", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"match", @"image", @"streamable", nil]];
}
- (NSArray *)searchForArtist:(NSString *)artist {
	NSArray *nodes = [self doMethod:@"artist.search" maxCacheAge:1*HOURS XPath:@"./results/artistmatches/artist" withParameters:[NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./streamable", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"streamable", nil]];
}

#pragma mark Album methods

- (NSDictionary *)metadataForAlbum:(NSString *)album byArtist:(NSString *)artist inLanguage:(NSString *)lang {
	NSDictionary *metadata = nil;
	NSArray *nodes = [self doMethod:@"album.getInfo" maxCacheAge:7*DAYS XPath:@"./album" withParameters:[NSString stringWithFormat:@"album=%@", [album URLEscaped]], [NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
	if([nodes count]) {
		CXMLNode *node = [nodes objectAtIndex:0];
		metadata = [self _convertNode:node
					 toDictionaryWithXPaths:[NSArray arrayWithObjects:@"./name", @"./image[@size=\"large\"]", nil]
													forKeys:[NSArray arrayWithObjects:@"name", @"image", nil]];
	}
	return metadata;
}

#pragma mark Track methods

- (void)loveTrack:(NSString *)title byArtist:(NSString *)artist {
	[self doMethod:@"track.love" maxCacheAge:0 XPath:@"." withParameters:[NSString stringWithFormat:@"track=%@", [title URLEscaped]], [NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
}
- (void)banTrack:(NSString *)title byArtist:(NSString *)artist {
	[self doMethod:@"track.ban" maxCacheAge:0 XPath:@"." withParameters:[NSString stringWithFormat:@"track=%@", [title URLEscaped]], [NSString stringWithFormat:@"artist=%@", [artist URLEscaped]], nil];
}
- (NSArray *)fansOfTrack:(NSString *)track byArtist:(NSString *)artist {
	NSArray *nodes = [self doMethod:@"track.getTopFans" maxCacheAge:7*DAYS XPath:@"./topfans/user" withParameters:[NSString stringWithFormat:@"track=%@", [track URLEscaped]], [NSString stringWithFormat:@"artist=%@", [artist URLEscaped]],nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./weight", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"username", @"weight", @"image", nil]];
}
- (NSArray *)topTagsForTrack:(NSString *)track byArtist:(NSString *)artist {
	NSArray *nodes = [self doMethod:@"track.getTopTags" maxCacheAge:7*DAYS XPath:@"./toptags/tag" withParameters:[NSString stringWithFormat:@"track=%@", [track URLEscaped]], [NSString stringWithFormat:@"artist=%@", [artist URLEscaped]],nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./count", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"count", nil]];
}
- (void)recommendTrack:(NSString *)track byArtist:(NSString *)artist toEmailAddress:(NSString *)emailAddress {
	[self doMethod:@"track.share" maxCacheAge:0 XPath:@"." withParameters:[NSString stringWithFormat:@"track=%@", [track URLEscaped]],
	 [NSString stringWithFormat:@"artist=%@", [artist URLEscaped]],
	 [NSString stringWithFormat:@"recipient=%@", [emailAddress URLEscaped]],
	 nil];
}

#pragma mark User methods

- (NSDictionary *)getMobileSessionForUser:(NSString *)username password:(NSString *)password {
	NSString *authToken = [[NSString stringWithFormat:@"%@%@", [username lowercaseString], [password md5sum]] md5sum];
	NSArray *nodes = [self doMethod:@"auth.getMobileSession" maxCacheAge:0 XPath:@"./session" withParameters:[NSString stringWithFormat:@"username=%@", [[username lowercaseString] URLEscaped]], [NSString stringWithFormat:@"authToken=%@", [authToken URLEscaped]], nil];
	if([nodes count])
		return [self _convertNode:[nodes objectAtIndex:0]
			 toDictionaryWithXPaths:[NSArray arrayWithObjects:@"./key", @"./subscriber", nil]
											forKeys:[NSArray arrayWithObjects:@"key", @"subscriber", nil]];
	else
		return nil;
}
- (NSArray *)topArtistsForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getTopArtists" maxCacheAge:5*MINUTES XPath:@"./topartists/artist" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./playcount", @"./streamable", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"playcount", @"streamable", @"image", nil]];
}
- (NSArray *)topAlbumsForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getTopAlbums" maxCacheAge:5*MINUTES XPath:@"./topalbums/album" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./playcount", @"./artist/name", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"playcount", @"artist", @"image", nil]];
}
- (NSArray *)topTracksForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getTopTracks" maxCacheAge:5*MINUTES XPath:@"./toptracks/track" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./playcount", @"./artist/name", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"playcount", @"artist", @"image", nil]];
}
- (NSArray *)tagsForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getTopTags" maxCacheAge:1*HOURS XPath:@"./toptags/tag" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./count", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"count", nil]];
}
- (NSArray *)playlistsForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getPlaylists" maxCacheAge:5*MINUTES XPath:@"./playlists/playlist" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./id", @"./title", @"./size", @"./streamable", nil]
										 forKeys:[NSArray arrayWithObjects:@"id", @"title", @"size", @"./streamable", nil]];
}
- (NSArray *)recentlyPlayedTracksForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getRecentTracks" maxCacheAge:0 XPath:@"./recenttracks/track" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./artist", @"./name", @"./date", nil]
										 forKeys:[NSArray arrayWithObjects:@"artist", @"name", @"date", nil]];
}
- (NSArray *)friendsOfUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getFriends" maxCacheAge:0 XPath:@"./friends/user" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"username", @"image", nil]];
}
- (NSArray *)eventsForUser:(NSString *)username {
	NSArray *nodes = [self doMethod:@"user.getEvents" maxCacheAge:0 XPath:@"./events/event" withParameters:[NSString stringWithFormat:@"user=%@", [username URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./id", @"./artists/headliner", @"./artists/artist", @"./title", @"./description", @"./venue/name", @"./venue/location/street", @"./venue/location/city", @"./venue/location/postalcode", @"./venue/location/country", @"./startDate", @"./image[@size=\"medium\"]", nil]
										 forKeys:[NSArray arrayWithObjects:@"id", @"headliner", @"artists", @"title", @"description", @"venue", @"street", @"city", @"postalcode", @"country", @"startDate", @"image", nil]];
}

#pragma mark Tag methods

- (NSArray *)tagsSimilarTo:(NSString *)tag {
	NSArray *nodes = [self doMethod:@"tag.getSimilar" maxCacheAge:7*DAYS XPath:@"./similartags/tag" withParameters:[NSString stringWithFormat:@"tag=%@", [tag URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", @"./streamable", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", @"streamable", nil]];
}
- (NSArray *)searchForTag:(NSString *)tag {
	NSArray *nodes = [self doMethod:@"tag.search" maxCacheAge:1*HOURS XPath:@"./results/tagmatches/tag" withParameters:[NSString stringWithFormat:@"tag=%@", [tag URLEscaped]], nil];
	return [self _convertNodes:nodes
					 toArrayWithXPaths:[NSArray arrayWithObjects:@"./name", nil]
										 forKeys:[NSArray arrayWithObjects:@"name", nil]];
}

#pragma mark Radio methods

- (NSDictionary *)tuneRadioStation:(NSString *)stationURL {
	NSDictionary *station = nil;
	NSArray *nodes = [self doMethod:@"radio.tune" maxCacheAge:0 XPath:@"./station" withParameters:[NSString stringWithFormat:@"station=%@", [stationURL URLEscaped]],
										[NSString stringWithFormat:@"discovery=%i", [[[NSUserDefaults standardUserDefaults] objectForKey:@"discovery"] intValue]],
										[NSString stringWithFormat:@"rtp=%i", [[[NSUserDefaults standardUserDefaults] objectForKey:@"scrobbling"] intValue]],
										nil];
	if([nodes count]) {
		CXMLNode *node = [nodes objectAtIndex:0];
		station = [self _convertNode:node
					toDictionaryWithXPaths:[NSArray arrayWithObjects:@"./name", @"./type", nil]
												 forKeys:[NSArray arrayWithObjects:@"name", @"type", nil]];
	}
	return station;
}
- (NSDictionary *)getPlaylist {
	NSMutableArray *playlist = nil;
	NSArray *nodes = [[[[[self doMethod:@"radio.getPlaylist" maxCacheAge:0 XPath:@"." withParameters:[NSString stringWithFormat:@"mobile_net=%@",[((MobileLastFMApplicationDelegate *)[UIApplication sharedApplication].delegate) hasWiFiConnection]?@"wifi":@"wwan"], nil] objectAtIndex:0] children] objectAtIndex:1] children];
	NSString *title = nil;
	
	for(CXMLNode *node in nodes) {
		if([[node name] isEqualToString:@"trackList"]) {
			playlist = [[[NSMutableArray alloc] init] autorelease];
			
			for(CXMLNode *tracklistNode in [node children]) {
				if([[tracklistNode name] isEqualToString:@"track"]) {
					NSArray *trackNodes = [tracklistNode children];
					NSEnumerator *trackMembers = [trackNodes objectEnumerator];
					CXMLNode *trackNode = nil;
					NSMutableDictionary *track = [[NSMutableDictionary alloc] init];
					
					while ((trackNode = [trackMembers nextObject])) {
						if([[trackNode name] isEqualToString:@"extension"]) {
							for(CXMLNode *extNode in [trackNode children]) {
								if([extNode stringValue])
									[track setObject:[extNode stringValue] forKey:[extNode name]];
							}
						} else if([trackNode stringValue])
							[track setObject:[trackNode stringValue] forKey:[trackNode name]];
					}
					
					[playlist addObject:track];
					[track release];
				}
			}
		} else if([[node name] isEqualToString:@"title"] && [node stringValue]) {
			NSMutableString *station = [NSMutableString stringWithString:[node stringValue]];
			[station replaceOccurrencesOfString:@"+" withString:@" " options:NSLiteralSearch range:NSMakeRange(0, [station length])];
			[station replaceOccurrencesOfString:@"-" withString:@" " options:NSLiteralSearch range:NSMakeRange(0, [station length])];
			title = [(NSString *)CFURLCreateStringByReplacingPercentEscapes(NULL,(CFStringRef)[station stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]],CFSTR("")) autorelease];
		}
	}
	return [NSDictionary dictionaryWithObjectsAndKeys:playlist,@"playlist",title,@"title",nil]; 
}

#pragma mark Event methods

- (void)attendEvent:(int)event status:(int)status {
	[self doMethod:@"event.attend" maxCacheAge:0 XPath:@"." withParameters:[NSString stringWithFormat:@"event=%i", event], [NSString stringWithFormat:@"status=%i", status], nil];
}

@end
