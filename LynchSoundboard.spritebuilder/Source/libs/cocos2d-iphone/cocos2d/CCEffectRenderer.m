//
//  CCEffectRenderer.m
//  cocos2d-ios
//
//  Created by Thayer J Andrews on 5/21/14.
//
//

#import "CCEffectRenderer.h"
#import "CCConfiguration.h"
#import "CCDirector.h"
#import "CCEffect.h"
#import "CCEffectStack.h"
#import "CCTexture.h"
#import "ccUtils.h"

#import "CCEffect_Private.h"
#import "CCRenderer_Private.h"
#import "CCSprite_Private.h"
#import "CCTexture_Private.h"


@interface CCEffectRenderTarget : NSObject

@property (nonatomic, readonly) CCTexture *texture;
@property (nonatomic, readonly) GLuint FBO;
@property (nonatomic, readonly) GLuint depthRenderBuffer;
@property (nonatomic, readonly) BOOL glResourcesAllocated;

@end

@implementation CCEffectRenderTarget

- (id)init
{
    if((self = [super init]))
    {
    }
    return self;
}

- (void)dealloc
{
    if (self.glResourcesAllocated)
    {
        [self destroyGLResources];
    }
}

- (BOOL)setupGLResourcesWithSize:(CGSize)size
{
    NSAssert(!_glResourcesAllocated, @"");
    
    CCGL_DEBUG_PUSH_GROUP_MARKER("CCEffectRenderTarget: allocateRenderTarget");
    
	// Textures may need to be a power of two
	NSUInteger powW;
	NSUInteger powH;
    
	if( [[CCConfiguration sharedConfiguration] supportsNPOT] )
    {
		powW = size.width;
		powH = size.height;
	}
    else
    {
		powW = CCNextPOT(size.width);
		powH = CCNextPOT(size.height);
	}
    
    static const CCTexturePixelFormat kRenderTargetDefaultPixelFormat = CCTexturePixelFormat_RGBA8888;
    
    // Create a new texture object for use as the color attachment of the new
    // FBO.
	_texture = [[CCTexture alloc] initWithData:nil pixelFormat:kRenderTargetDefaultPixelFormat pixelsWide:powW pixelsHigh:powH contentSizeInPixels:size contentScale:[CCDirector sharedDirector].contentScaleFactor];
	_texture.antialiased = NO;
	
    // Save the old FBO binding so it can be restored after we create the new
    // one.
	GLint oldFBO;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &oldFBO);
    
	// Generate a new FBO and bind it so it can be modified.
	glGenFramebuffers(1, &_FBO);
	glBindFramebuffer(GL_FRAMEBUFFER, _FBO);
    
	// Associate texture with FBO
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _texture.name, 0);
    
	// Check if it worked (probably worth doing :) )
	NSAssert( glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, @"Could not attach texture to framebuffer");
    
    // Restore the old FBO binding.
	glBindFramebuffer(GL_FRAMEBUFFER, oldFBO);
	
	CC_CHECK_GL_ERROR_DEBUG();
	CCGL_DEBUG_POP_GROUP_MARKER();
    
    _glResourcesAllocated = YES;
    return YES;
}

- (void)destroyGLResources
{
    NSAssert(_glResourcesAllocated, @"");
    glDeleteFramebuffers(1, &_FBO);
    if (_depthRenderBuffer)
    {
        glDeleteRenderbuffers(1, &_depthRenderBuffer);
    }
    
    _texture = nil;
    
    _glResourcesAllocated = NO;
}

@end


@interface CCEffectRenderer ()

@property (nonatomic, strong) NSMutableArray *allRenderTargets;
@property (nonatomic, strong) NSMutableArray *freeRenderTargets;
@property (nonatomic, assign) GLKVector4 oldViewport;
@property (nonatomic, assign) GLint oldFBO;

+(CCShader *)sharedCopyShader;

@end


@implementation CCEffectRenderer

+ (CCShader *)sharedCopyShader
{
	static dispatch_once_t once;
	static CCShader *copyShader = nil;
	dispatch_once(&once, ^{
        copyShader = [[CCShader alloc] initWithFragmentShaderSource:@"void main(){gl_FragColor = texture2D(cc_MainTexture, cc_FragTexCoord1);}"];
        copyShader.debugName = @"CCEffectRendererTextureCopyShader";
	});
	return copyShader;
}

-(id)init
{
    if((self = [super init]))
    {
        _allRenderTargets = [[NSMutableArray alloc] init];
        _freeRenderTargets = [[NSMutableArray alloc] init];
        _contentSize = CGSizeMake(1.0f, 1.0f);
        _contentScale = [CCDirector sharedDirector].contentScaleFactor;
    }
    return self;
}

-(void)dealloc
{
    [self destroyAllRenderTargets];
}

-(void)drawSprite:(CCSprite *)sprite withEffect:(CCEffect *)effect uniforms:(NSMutableDictionary *)uniforms renderer:(CCRenderer *)renderer transform:(const GLKMatrix4 *)transform
{
    NSAssert(effect.readyForRendering, @"Effect not ready for rendering. Call prepareForRendering first.");
    [self freeAllRenderTargets];
    
    CCEffectRenderTarget *previousPassRT = nil;
    for(NSUInteger i = 0; i < effect.renderPassesRequired; i++)
    {
        BOOL lastPass = (i == (effect.renderPassesRequired - 1));
        BOOL directRendering = lastPass && effect.supportsDirectRendering;
        
        CCTexture *previousPassTexture = nil;
        if (previousPassRT)
        {
            NSAssert(previousPassRT.texture, @"Texture for render target unexpectedly nil.");
            previousPassTexture = previousPassRT.texture;
        }
        else
        {
            previousPassTexture = sprite.texture ?: [CCTexture none];
        }
        
        CCEffectRenderPass* renderPass = [effect renderPassAtIndex:i];
        renderPass.renderer = renderer;
        renderPass.renderPassId = i;
        renderPass.verts = *(sprite.vertexes);
        renderPass.blendMode = [CCBlendMode premultipliedAlphaMode];
        renderPass.needsClear = !directRendering;
        renderPass.shaderUniforms = uniforms;
        
        CCEffectRenderTarget *rt = nil;
        
        [renderer pushGroup];
        if (directRendering)
        {
            renderPass.transform = *transform;

            GLKMatrix4 ndcToWorldMat;
            [renderer.globalShaderUniforms[CCShaderUniformProjectionInv] getValue:&ndcToWorldMat];
            renderPass.ndcToWorld = ndcToWorldMat;
            
            [renderPass begin:previousPassTexture];
            [renderPass update];
            [renderPass end];
        }
        else
        {
            bool inverted;
            
            GLKMatrix4 renderTargetProjection = GLKMatrix4MakeOrtho(0.0f, _contentSize.width, 0.0f, _contentSize.height, -1024.0f, 1024.0f);
            GLKMatrix4 invRenderTargetProjection = GLKMatrix4Invert(renderTargetProjection, &inverted);
            NSAssert(inverted, @"Unable to invert matrix.");
            
            GLKMatrix4 invGlobalProjection;
            [renderer.globalShaderUniforms[CCShaderUniformProjectionInv] getValue:&invGlobalProjection];
            
            GLKMatrix4 ndcToNodeMat = invRenderTargetProjection;
            GLKMatrix4 nodeToWorldMat = GLKMatrix4Multiply(invGlobalProjection, *transform);
            GLKMatrix4 ndcToWorldMat = GLKMatrix4Multiply(nodeToWorldMat, ndcToNodeMat);

            renderPass.transform = renderTargetProjection;
            renderPass.ndcToWorld = ndcToWorldMat;
            
            CGSize rtSize = CGSizeMake(_contentSize.width * _contentScale, _contentSize.height * _contentScale);
            rtSize.width = (rtSize.width <= 1.0f) ? 1.0f : rtSize.width;
            rtSize.height = (rtSize.height <= 1.0f) ? 1.0f : rtSize.height;
            
            rt = [self renderTargetWithSize:rtSize];
            
            [renderPass begin:previousPassTexture];
            [self bindRenderTarget:rt withRenderer:renderer];
            [renderPass update];
            [self restoreRenderTargetWithRenderer:renderer];
            [renderPass end];
        }
        [renderer popGroupWithDebugLabel:renderPass.debugLabel globalSortOrder:0];
        
        previousPassRT = rt;
    }
    
    if (!effect.supportsDirectRendering)
    {
        // If the effect doesn't support direct renderering then we need one last
        // draw to composite the effect results into the displayable framebuffer.
        [renderer pushGroup];

        CCTexture *backup = sprite.texture;
        sprite.shader = [CCEffectRenderer sharedCopyShader];
        sprite.texture = previousPassRT.texture;
        [sprite enqueueTriangles:renderer transform:transform];
        sprite.texture = backup;
        
        [renderer popGroupWithDebugLabel:@"CCEffectRenderer: Post-render composite pass" globalSortOrder:0];
    }
    else if (!effect.renderPassesRequired)
    {
        [sprite enqueueTriangles:renderer transform:transform];
    }
}

- (void)bindRenderTarget:(CCEffectRenderTarget *)rt withRenderer:(CCRenderer *)renderer
{
    CGSize pixelSize = rt.texture.contentSizeInPixels;
    GLuint fbo = rt.FBO;
    
    [renderer enqueueBlock:^{
        glGetFloatv(GL_VIEWPORT, _oldViewport.v);
        glViewport(0, 0, pixelSize.width, pixelSize.height );
        
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &_oldFBO);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        
    } globalSortOrder:NSIntegerMin debugLabel:@"CCEffectRenderer: Bind FBO" threadSafe:NO];
}

- (void)restoreRenderTargetWithRenderer:(CCRenderer *)renderer
{
    [renderer enqueueBlock:^{
        glBindFramebuffer(GL_FRAMEBUFFER, _oldFBO);
        glViewport(_oldViewport.v[0], _oldViewport.v[1], _oldViewport.v[2], _oldViewport.v[3]);
    } globalSortOrder:NSIntegerMax debugLabel:@"CCEffectRenderer: Restore FBO" threadSafe:NO];
    
}

- (CCEffectRenderTarget *)renderTargetWithSize:(CGSize)size
{
    NSAssert((size.width > 0.0f) && (size.height > 0.0f), @"Render targets must have non-zero dimensions.");

    // If there is a free render target available for use, return that one. If
    // not, create a new one and return that.
    CCEffectRenderTarget *rt = nil;
    if (_freeRenderTargets.count)
    {
        rt = [_freeRenderTargets lastObject];
        [_freeRenderTargets removeLastObject];
    }
    else
    {
        rt = [[CCEffectRenderTarget alloc] init];
        [rt setupGLResourcesWithSize:size];
        [_allRenderTargets addObject:rt];
    }
    return rt;
}

- (void)destroyAllRenderTargets
{
    // Destroy all allocated render target objects and the associated GL resources.
    for (CCEffectRenderTarget *rt in _allRenderTargets)
    {
        [rt destroyGLResources];
    }
    [_allRenderTargets removeAllObjects];
    [_freeRenderTargets removeAllObjects];
}

- (void)freeRenderTarget:(CCEffectRenderTarget *)rt
{
    // Put the supplied render target back into the free list. If it's already there
    // them somebody is doing something wrong.
    NSAssert(![_freeRenderTargets containsObject:rt], @"Double freeing a render target!");
    [_freeRenderTargets addObject:rt];
}

- (void)freeAllRenderTargets
{
    // Reset the free render target list to contain all allocated render targets.
    [_freeRenderTargets removeAllObjects];
    [_freeRenderTargets addObjectsFromArray:_allRenderTargets];
}

@end
