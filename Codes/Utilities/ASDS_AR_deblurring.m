function [im_out PSNR SSIM]   =  ASDS_AR_deblurring( par )
time0       =   clock;

bim         =   par.bim;
[h  w ch]   =   size(bim);

par.win    =   7;
par.step   =   3;
par.sigma  =   1.4;
par.h      =   h;
par.w      =   h;
par.tau    =   par.tau;

dim         =   uint8(zeros(h, w, ch));
ori_im      =   zeros(h,w);

% RGB->YUV
%
if  ch == 3
    b_im           =   rgb2ycbcr( uint8(bim) );
    dim(:,:,2)     =   b_im(:,:,2);
    dim(:,:,3)     =   b_im(:,:,3);
    b_im           =   double( b_im(:,:,1));
    
    if isfield(par, 'I')
        ori_im         =   rgb2ycbcr( uint8(par.I) );
        ori_im         =   double( ori_im(:,:,1));
    end
else
    b_im           =   bim;
    
    if isfield(par, 'I')
        ori_im             =   par.I;
    end
end
disp(sprintf('The PSNR of the blurred image = %f \n', csnr(b_im(1:h,1:w), ori_im, 0, 0) ));

d_im       =   Deblurring( b_im, par, ori_im );


if isfield(par,'I')
   [h w ch]  =  size(par.I);
   PSNR      =  csnr( d_im(1:h,1:w), ori_im, 0, 0 );
   SSIM      =  cal_ssim( d_im(1:h,1:w), ori_im, 0, 0 );
end

if ch==3
    dim(:,:,1)   =  uint8(d_im);
    im_out       =  double(ycbcr2rgb( dim ));
else
    im_out  =  d_im;
end
    
% disp(sprintf('Total elapsed time = %f min\n', (etime(clock,time0)/60) ));

return;


%----------------------------------------------------------------------
% The sparse approximation based image restoration
%
%----------------------------------------------------------------------
function d_im  = Deblurring( b_im, par, ori_im )

d_im      =   b_im;
[h   w]   =   size(d_im);
[h1 w1]   =   size(ori_im);

fft_h   =   par.fft_h;
Y_f     =   fft2(b_im);
A_f     =   conj(fft_h).*Y_f;
H2_f    =   abs(fft_h).^2;
Tau     =   zeros(0);
flag    =   0;

for k   =  1:1
    
    if par.method==2
        A            =   Compute_AR_Matrix( d_im, par );
        N            =   Compute_NLM_Matrix( d_im, 5, par );
        ATA          =   A'*A*par.gam;
        NTN          =   N'*N*par.eta;
    elseif par.method==1
        A            =   Compute_AR_Matrix( d_im, par );
        ATA          =   A'*A*par.gam;
    end
    
    [Arr  Wei]    =    find_blks( d_im, par );
    [PCA_D, D0, cls_idx, s_idx, seg]    =   Set_PCA_idx( d_im, par, par.Codeword );         %  Set_PCA_idx_New( d_im, opts, par.PCA_D, DCT );
    S             =    @(x) LPCA_IS_fast( x, cls_idx, PCA_D, par, s_idx, seg, D0, flag, Tau, Arr, Wei );
    f             =    b_im;  %d_im;          

    for  iter = 1 : par.nIter
              
        f_pre    =  f;
        
        if (mod(iter, 150) == 0) 
            if  (iter>=700)   flag = 1;  end
            [PCA_D, D0, cls_idx, s_idx, seg]   =  Set_PCA_idx( f, par, par.Codeword );
            
            if ( iter>= 700 )
                Tau     =   Cal_Sparsity_Parameters( f, cls_idx, PCA_D, par, s_idx, seg, D0, Arr, Wei );
            end
            S           =   @(x) LPCA_IS_fast( x, cls_idx, PCA_D, par, s_idx, seg, D0, flag, Tau, Arr, Wei );            
            
            if (iter==300 ||iter==600)
                if par.method==2
                    A            =    Compute_AR_Matrix( f, par );
                    ATA          =    A'*A*par.gam;            
                    N            =    Compute_NLM_Matrix( f, 5, par );                
                    NTN          =    N'*N*par.eta;
                    [Arr  Wei]   =    find_blks( f, par );
                    S            =    @(x) LPCA_IS_fast( x, cls_idx, PCA_D, par, s_idx, seg, D0, flag, Tau, Arr, Wei );
                elseif par.method==1
                    A            =   Compute_AR_Matrix( f, par );
                    ATA          =   A'*A*par.gam;            
                end                
            end                
        end        
    
        
        im_f     =   fft2((f_pre));
        Z_f      =   im_f + (A_f - H2_f.*im_f)./(H2_f + 0.23);
        z        =   real(ifft2((Z_f)));
        f1       =   max(min(z,255),0);        
        
        v    =  f_pre(:);
        if par.method==2
            f1       =   f1  - reshape(ATA*v + NTN*v, h, w);
        elseif par.method==1
            f1       =   f1  - reshape( ATA*v, h, w );
        end
        f         =  S( f1 );
        
        
        if (mod(iter, 40) == 0)
            if isfield(par,'I')
                PSNR     =  csnr( f(1:h1,1:w1), ori_im, 0, 0 );
                fprintf( 'Preprocessing, Iter %d : PSNR = %f\n', iter, PSNR );
            end
            dif       =  mean((f(:)-f_pre(:)).^2);
            if (dif<par.eps) 
                break; 
            end            
        end                 
        
    end
    d_im   =  f;
end


%--------------------------------------------------------------------------
% Utilities functions
%--------------------------------------------------------------------------
function  Tau1    =   Cal_Sparsity_Parameters( im, PCA_idx, PCA_D, par, s_idx, seg, A, Arr, Wei )
b        =  par.win;
s        =  par.step;
b2       =  b*b;
[h  w]   =  size(im);

N       =  h-b+1;
M       =  w-b+1;
r       =  [1:s:N];
r       =  [r r(end)+1:N];
c       =  [1:s:M];
c       =  [c c(end)+1:M];
X0      =  zeros(b*b, N*M);
X_m     =  zeros(b*b,length(r)*length(c),'single');
N       =  length(r);
M       =  length(c);
L       =  N*M;

% For the Y component
k    =  0;
for i  = 1:b
    for j  = 1:b
        k        =  k+1;        
        blk      =  im(i:end-b+i,j:end-b+j);
        X0(k,:)  =  blk(:)';
    end
end
% Compute the mean blks
idx      =   s_idx(seg(1)+1:seg(2));
set      =   1:size(X_m,2);
set(idx) =   [];

for i = 1:par.nblk
   v            =  Wei(i,set);
   X_m(:,set)   =  X_m(:,set) + X0(:, Arr(i, set)) .*v(ones(b2,1), :);
end

% X_m     =  zeros(length(r)*length(c),b*b,'single');
% X = X0';
% for i = 1:par.nblk
%    v            =  Wei(set,i);
%    X_m(set,:)   =  X_m(set,:) + X(Arr(set,i),:) .*v(:, ones(1,b2));
% end
% X_m=X_m';


Cu0      =   zeros(b2, L, 'single' );
coe      =   A*X0(:, idx);
Cu0(:,idx)  =  abs(coe);

% for  k  =  1 : length(idx)
%     i          =   idx(k);
% %     coe        =   A*(X0(:, Arr(:, i)) - repmat(X_m(:, i), 1, par.nblk) );
%     coe        =   A*X0(:, Arr(:, i));
%     Cu0(:,i)   =   sqrt( mean(coe.^2, 2) );    
% end

set        =   1:L;
set(idx)   =   [];
L          =   length(set);

for  k  =  1 : L
    i         =   set(k);
    cls       =   PCA_idx(i);
    P         =   reshape(PCA_D(:, cls), b2, b2);
    
    coe       =   P*(X0(:, Arr(:,i)) - repmat(X_m(:, i), 1, par.nblk) );
    Cu0(:,i)  =   sqrt( mean(coe.^2, 2) );
end
e        =   0.5;
Tau1     =   par.c1./(abs(Cu0) + e);    

