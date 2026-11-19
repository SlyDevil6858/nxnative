    for (UIView *view in _themeMenuScroll.subviews) [view removeFromSuperview];

    NSURL *documentsRoot=[self themesDirectoryCreating:YES];
    NSURL *bundledRoot=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES];
    NSMutableArray<NSURL *> *bundledFolders=[[NSFileManager.defaultManager contentsOfDirectoryAtURL:bundledRoot
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] mutableCopy] ?: [NSMutableArray array];
    NSURL *selectedOverride=[self selectedOverrideThemeDirectory];
    if (selectedOverride) [bundledFolders addObject:selectedOverride];
    NSArray<NSURL *> *importedFolders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:documentsRoot
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    BOOL hasDocumentsForest=NO;
    for (NSURL *folder in importedFolders) if ([folder.lastPathComponent caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) { hasDocumentsForest=YES; break; }
    BOOL forestWasDeleted=[NSFileManager.defaultManager fileExistsAtPath:[[documentsRoot URLByAppendingPathComponent:@".FOREST.deleted"] path]];
    NSMutableArray<NSURL *> *visibleBundled=[NSMutableArray array];
    for (NSURL *folder in bundledFolders) {
        if ((hasDocumentsForest || forestWasDeleted) && [folder.lastPathComponent caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) continue;
        [visibleBundled addObject:folder];
    }
    NSArray<NSURL *> *unsortedFolders=[visibleBundled arrayByAddingObjectsFromArray:importedFolders];
    NSArray<NSURL *> *folders=[unsortedFolders sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        NSString *(^normalizedName)(NSString *) = ^NSString *(NSString *value) {
            NSString *name=[[value uppercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
            name=[name stringByReplacingOccurrencesOfString:@"-" withString:@" "];
            for (NSString *suffix in @[@" SKIN", @" THEME"]) if ([name hasSuffix:suffix])
                name=[[name substringToIndex:name.length-suffix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        };
        NSInteger (^priority)(NSURL *) = ^NSInteger(NSURL *folder) {
            NSString *folderName=normalizedName(folder.lastPathComponent);
            NSDictionary *json=[self validThemeJSONAtFolder:folder];
            NSString *themeName=normalizedName([json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : folder.lastPathComponent);
            NSString *selectedOverridePath=[self selectedOverrideThemeDirectory].standardizedURL.path;
            if (selectedOverridePath.length && [folder.standardizedURL.path isEqualToString:selectedOverridePath]) return 0;
            if ([folderName isEqualToString:@"CLASSIC"] || [themeName isEqualToString:@"CLASSIC"]) return 1;
            return 2;
        };
        NSInteger lp=priority(left),rp=priority(right);
        if(lp<rp)return NSOrderedAscending;if(lp>rp)return NSOrderedDescending;
        NSDictionary *lj=[self validThemeJSONAtFolder:left],*rj=[self validThemeJSONAtFolder:right];
        NSString *ln=[lj[@"name"] isKindOfClass:NSString.class]?lj[@"name"]:left.lastPathComponent;
        NSString *rn=[rj[@"name"] isKindOfClass:NSString.class]?rj[@"name"]:right.lastPathComponent;
        NSComparisonResult byName=[ln localizedCaseInsensitiveCompare:rn];
        return byName==NSOrderedSame?[left.path localizedCaseInsensitiveCompare:right.path]:byName;
    }];
    // Keep the override belonging to this ROM at the absolute top of the
    // control-editor list, independently of the alphabetical/priority sort.
    NSString *selectedOverridePath=selectedOverride.standardizedURL.path;
    if (selectedOverridePath.length) {
        NSMutableArray<NSURL *> *orderedFolders=[folders mutableCopy];
        NSUInteger selectedIndex=[orderedFolders indexOfObjectPassingTest:^BOOL(NSURL *folder, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop;
            return [folder.standardizedURL.path isEqualToString:selectedOverridePath];
        }];
        if (selectedIndex != NSNotFound && selectedIndex != 0) {
            NSURL *romOverride=[orderedFolders objectAtIndex:selectedIndex];
            [orderedFolders removeObjectAtIndex:selectedIndex];
            [orderedFolders insertObject:romOverride atIndex:0];
        }
        folders=orderedFolders;
    }

    CGFloat rowHeight=48;
    NSUInteger row=0;
    for (NSURL *folder in folders) {
        BOOL isDir=NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&isDir] || !isDir) continue;
        NSDictionary *json=[self validThemeJSONAtFolder:folder];