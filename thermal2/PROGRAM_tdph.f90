!
! Copyright (C) 2001-2012 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
MODULE tdph_module
  USE kinds, ONLY : DP
#include "mpi_thermal.h"
  !
  TYPE dynmat_basis
     COMPLEX(DP),ALLOCATABLE :: basis(:,:,:)
  END TYPE

  INTEGER :: nfar=0

  TYPE tdph_input_type
    !
    CHARACTER(len=256) :: md = 'md.out'
    CHARACTER(len=256) :: file_mat2 = 'mat2R.periodic'
    CHARACTER(len=8) :: fit_type = "force"
    INTEGER :: nfirst, nskip, nmax, nprint
    REAL(DP) :: e0
    !
  END TYPE tdph_input_type
  !
  CONTAINS
  !
  ! read everything from files mat2R and mat3R
  SUBROUTINE READ_INPUT_TDPH(input)
    USE code_input,           ONLY : parse_command_line
    USE cmdline_param_module, ONLY : cmdline_to_namelist
    !
    IMPLICIT NONE
    !
    TYPE(tdph_input_type),INTENT(out) :: input
    CHARACTER(len=256)  :: input_file
    INTEGER :: ios
    !
    ! Input variable, and defaul values:
    CHARACTER(len=256) :: md = 'md.out'
    CHARACTER(len=256) :: file_mat2 = 'mat2R.periodic'
    CHARACTER(len=8) :: fit_type = "force"
    INTEGER :: nfirst=1000, nskip=100, nmax=10000, nprint=1000

    INTEGER :: input_unit, aux_unit
    !CHARACTER(len=6), EXTERNAL :: int_to_char
    INTEGER,EXTERNAL :: find_free_unit
    REAL(DP) :: e0 = 0._dp
    !
    NAMELIST  / tdphinput / &
        md, file_mat2, fit_type, &
        nfirst, nskip, nmax, nprint, &
        e0

    WRITE(*,*) "Waiting for input"
    !
    input_file="input.TDPH"
    CALL parse_command_line(input_file)
    IF(TRIM(input_file)=="-")THEN
      ioWRITE(stdout,'(2x,3a)') "Warning! Reading standard input will probably not work with MPI"
      input_unit = 5
    ELSE
      ioWRITE(stdout,'(2x,3a)') "Reading input file '", TRIM(input_file), "'"
      !input_unit = find_free_unit()
      OPEN(newunit=input_unit, file=input_file, status="OLD", action="READ")
    ENDIF
    !
    aux_unit = find_free_unit()
    READ(input_unit, tdphinput)
    WRITE(stdout,'(2x,3a)') "merging with command line arguments"
    OPEN(unit=aux_unit, file=TRIM(input_file)//".tmp~", status="UNKNOWN", action="READWRITE")
    CALL cmdline_to_namelist("tdphinput", aux_unit)
    REWIND(aux_unit)
    READ(aux_unit, tdphinput)
    CLOSE(aux_unit, status="DELETE")

    WRITE(stdout, tdphinput)
    !
    !IF(ANY(<1))  CALL errore("READ_INPUT_TDPH","Invalid nk",1)

    IF(e0==0._dp .and. fit_type=='energy') &
        CALL errore("tdph","need zero energy to fit energy difference", 1)

    IF(ANY((/nfirst,nmax,nskip/)<1)) &
        CALL errore("tdph","wrong parameters", 1)
    !
    input%md            = md
    input%file_mat2     = file_mat2
    input%fit_type      = fit_type
    input%nfirst        = nfirst
    input%nskip         = nskip
    input%nmax          = nmax
    input%nprint        = nprint
    input%e0            = e0
    !
  END SUBROUTINE READ_INPUT_TDPH



  SUBROUTINE set_qe_global_geometry(Si)
    USE input_fc,           ONLY : ph_system_info
    USE cell_base,          ONLY : at, bg, celldm, ibrav, omega
    USE ions_base,          ONLY : nat, ityp, ntyp => nsp, atm, tau, amass
    USE noncollin_module,   ONLY : m_loc, nspin_mag
    !
    IMPLICIT NONE
    TYPE(ph_system_info),INTENT(in) :: Si
    !
    ! Quantum-ESPRESSO symmetry subroutines use the global variables
    ! we copy the system data from structure S
    ntyp   = Si%ntyp
    nat    = Si%nat
    IF(allocated(tau)) DEALLOCATE(tau)
    ALLOCATE(tau(3,nat))
    IF(allocated(ityp)) DEALLOCATE(ityp)
    ALLOCATE(ityp(nat))
    celldm = Si%celldm
    at     = Si%at
    bg     = Si%bg
    omega  = Si%omega
    atm(1:ntyp)    = Si%atm(1:ntyp)
    amass(1:ntyp)  = Si%amass(1:ntyp)
    tau(:,1:nat)   = Si%tau(:,1:nat)
    ityp(1:nat)    = Si%ityp(1:nat)
  
  END SUBROUTINE

END MODULE

!
!----------------------------------------------------------------------------
PROGRAM tdph
  !----------------------------------------------------------------------------
  !
  USE kinds,              ONLY : DP
  USE constants,          ONLY : amu_ry, K_BOLTZMANN_SI, K_BOLTZMANN_RY, RYTOEV !ry_to_kelvin
  USE parameters,         ONLY : ntypx
  USE mp,                 ONLY : mp_bcast
  USE mp_global,          ONLY : mp_startup, mp_global_end
  USE mp_world,           ONLY : world_comm
  USE environment,        ONLY : environment_start, environment_end
  ! symmetry
  USE symm_base,          ONLY : s, invs, nsym, find_sym, set_sym_bl, &
                                  irt, copy_sym, nrot, inverse_s, t_rev
  USE noncollin_module,   ONLY : m_loc, nspin_mag
  USE lr_symm_base,       ONLY : rtau, nsymq, minus_q, irotmq, gi, gimq, invsymq
  USE control_lr,         ONLY : lgamma
  USE decompose_d2,       ONLY : smallg_q_fullmq, find_d2_symm_base, sym_and_star_q, dotprodmat, &
                                 make_qstar_d2, allocate_sym_and_star_q, tr_star_q
  USE cmdline_param_module
  USE input_fc,           ONLY : forceconst2_grid, ph_system_info, read_system, aux_system, read_fc2, &
                                 div_mass_fc2, multiply_mass_dyn, write_fc2
  USE fc2_interpolate,    ONLY : fftinterp_mat2, mat2_diag, dyn_cart2pat
  USE asr2_module,        ONLY : impose_asr2
  USE quter_module,       ONLY : quter
  USE mpi_thermal,        ONLY : start_mpi, stop_mpi, num_procs
  USE tdph_module
  ! harmonic
  USE harmonic_module,    ONLY : read_md, harmonic_force
  ! minipack
  USE lmdif_module,       ONLY : lmdif1, lmdif
  USE timers
  !
  IMPLICIT NONE
  !
  CHARACTER(len=7),PARAMETER :: CODE="MKWEDGE"
  CHARACTER(len=256) :: fildyn, filout
  INTEGER :: ierr, nargs
  !
  INTEGER       :: nq1, nq2, nq3, nqmax, nq_wedge, nqq, nq_done

  REAL(DP),ALLOCATABLE      :: x_q(:,:), w_q(:)
  ! for harmonic_module
  REAL(DP),ALLOCATABLE      :: u(:,:,:), F_HAR(:,:,:), F_AI(:,:,:), force_diff(:), wa(:), &
                               force_ratio(:,:,:), tot_ene(:), h_energy(:)
  ! for lmdf1
  INTEGER                   :: n_steps, j_steps, mfcn, lwa 
  INTEGER, ALLOCATABLE      :: iwa(:)
  !
  REAL(DP) :: xq(3), syq(3,48)
  LOGICAL :: sym(48), lrigid_save, skip_equivalence, time_reversal
  !
  COMPLEX(DP),ALLOCATABLE :: phi(:,:,:,:), d2(:,:), w2(:,:), &
                             star_wdyn(:,:,:,:, :), star_dyn(:,:,:)
  REAL(DP),ALLOCATABLE :: decomposition(:), xqmax(:,:), ph_coefficients(:), &
                          ph_coefficients0(:), metric(:)
  INTEGER :: i,j, icar,jcar, na,nb, iq, nph, iph, iswitch, first_step, n_skip
  INTEGER,ALLOCATABLE :: rank(:)
  TYPE(ph_system_info) :: Si
  TYPE(forceconst2_grid) :: fc, fcout
  TYPE(dynmat_basis),ALLOCATABLE :: dmb(:)
  TYPE(sym_and_star_q),ALLOCATABLE :: symq(:)

  ! used for lmdif
  INTEGER :: nfev
  REAL(DP) :: factor
  INTEGER,ALLOCATABLE :: ipvt(:)
  REAL(DP),ALLOCATABLE :: fjac(:,:),qtf(:),wa1(:),wa2(:),wa3(:),wa4(:)
  TYPE(nanotimer) :: t_minim = nanotimer("minimization")
  TYPE(tdph_input_type) :: input
  !
  CALL start_mpi()
  !
  ! Read namelist tdphinput
  CALL READ_INPUT_TDPH(input)

  CALL read_fc2(input%file_mat2, Si, fc)
  lrigid_save = Si%lrigid
  Si%lrigid = .false.
  CALL impose_asr2("simple", Si%nat, fc, Si%zeu)
  CALL aux_system(Si)
  CALL div_mass_fc2(Si, fc)
  !
  CALL set_qe_global_geometry(Si)
  !
  ! ######################### symmetry setup #########################
  ! Symmetry setup uses global variable, which is not ideal, but
  ! not a huge problem since we only need to do this part once
  ! at the beginning.
  ! ~~~~~~~~ setup bravais lattice symmetry ~~~~~~~~ 
  CALL set_sym_bl ( )
  ioWRITE(stdout, '(5x,a,i3)') "Symmetries of bravais lattice: ", nrot
  !
  ! ~~~~~~~~ setup crystal symmetry ~~~~~~~~ 
  IF(.not.allocated(m_loc))  THEN
    ALLOCATE(m_loc(3,Si%nat))
    m_loc = 0._dp
  ENDIF
  
  CALL find_sym ( Si%nat, Si%tau, Si%ityp, .false., m_loc )
  ioWRITE(stdout, '(5x,a,i3)') "Symmetries of crystal:         ", nsym
  !
  ! Find the reduced grid of q-points:
  skip_equivalence = .FALSE.
  time_reversal    = .TRUE.
  nq1 = fc%nq(1)
  nq2 = fc%nq(2)
  nq3 = fc%nq(3)
  nqmax = nq1*nq2*nq3
  ALLOCATE(x_q(3,nqmax), w_q(nqmax))
  CALL kpoint_grid( nsym, time_reversal, skip_equivalence, s, t_rev, Si%bg, nqmax,&
                    0,0,0, nq1,nq2,nq3, nq_wedge, x_q, w_q )
  !
  ioWRITE(stdout, *) "Generated ", nq_wedge, "points"
  
  ALLOCATE(rtau( 3, 48, Si%nat), d2(3*Si%nat,3*Si%nat))

  ! Variable to hold the dyn matrix and q-points of the entire grid
  nq_done = 0
  ALLOCATE(star_wdyn(3,3,Si%nat,Si%nat, nqmax))
  ALLOCATE(xqmax(3,nqmax))

  ! For every q-point in the irreducible wedge, we find its symmetry
  ! and the basis of the space of symmetry-constrained dynfactoramical matrices
  ! Again, this part uses gloabl variables which is a annoying, but once
  ! we have the set of basis matrices, we don't have to touch it
  ! anymore.
  ALLOCATE(dmb(nq_wedge))
  ALLOCATE(rank(nq_wedge))
  ALLOCATE(symq(nq_wedge))

  Q_POINTS_LOOP : &
  DO iq = 1, nq_wedge
    ioWRITE(stdout, *) "____[[[[[[[", iq, "]]]]]]]]____"
    ioWRITE(stdout, '(i6, 3f12.4)') iq, x_q(:,iq)
    !
    ! ~~~~~~~~ setup small group of q symmetry ~~~~~~~~ 
    ! part 1: call smallg_q and the copy_sym, 
    xq = x_q(:,iq)
    minus_q = .true.
  
    sym = .false.
    sym(1:nsym) = .true.
    CALL smallg_q_fullmq(xq, 0, Si%at, Si%bg, nsym, s, sym, minus_q)
    nsymq = copy_sym(nsym, sym)
    ! recompute the inverses as the order of sym.ops. has changed
    CALL inverse_s ( ) 
  
    ! part 2: this computes gi, gimq
    call set_giq (xq,s,nsymq,nsym,irotmq,minus_q,gi,gimq)
!    WRITE(stdout, '(5x,a,i3)') "Symmetries of small group of q:", nsymq
!    IF(minus_q) WRITE(stdout, '(10x,a)') "in addition sym. q -> -q+G"
    !
    ! finally this does some of the above again and also computes rtau...
    CALL sgam_lr(Si%at, Si%bg, nsym, s, irt, Si%tau, rtau, Si%nat)
    !
    ! Now, I copy all the symmetry definitions to a derived type
    ! which I'm going to use EXCLUSIVELY from here on
    CALL allocate_sym_and_star_q(Si%nat, symq(iq))
    symq(iq)%xq = xq
    symq(iq)%nrot = nrot
    symq(iq)%nsym  = nsym
    symq(iq)%nsymq = nsymq
    symq(iq)%minus_q = minus_q
    symq(iq)%irotmq = irotmq
    symq(iq)%s = s
    symq(iq)%invs = invs
    symq(iq)%rtau = rtau
    symq(iq)%irt= irt

    !integer :: nrot, nsym, nsymq, irotmq
    !integer :: nq, nq_tr, isq (48), imq
    !real(DP) :: sxq (3, 48)
    !
    ! the next subroutine uses symmetry from global variables to find he basis of crystal-symmetric
    ! matrices at this q point
    CALL fftinterp_mat2(xq, Si, fc, d2)
    d2 = multiply_mass_dyn(Si,d2)

    CALL find_d2_symm_base(xq, rank(iq), dmb(iq)%basis, &
       Si%nat, Si%at, Si%bg, symq(iq)%nsymq, symq(iq)%minus_q, &
       symq(iq)%irotmq, symq(iq)%rtau, symq(iq)%irt, symq(iq)%s, symq(iq)%invs, d2 )
    !
    !
    ! Calculate the list of points making up the star of q and of -q
    CALL tr_star_q(symq(iq)%xq, Si%at, Si%bg, symq(iq)%nsym, symq(iq)%s, symq(iq)%invs, &
                   symq(iq)%nq_star, symq(iq)%nq_trstar, symq(iq)%sxq, &
                   symq(iq)%isq, symq(iq)%imq, .false. )

    ioWRITE(stdout, '(5x,a,2i5)') "Found star of q and -q", symq(iq)%nq_star, symq(iq)%nq_trstar
    syq = symq(iq)%sxq
    call cryst_to_cart(symq(iq)%nq_trstar, syq, Si%at, -1)
    DO i = 1, symq(iq)%nq_trstar
       syq(1,i) = MODULO(syq(1,i), 1._dp)
       syq(2,i) = MODULO(syq(2,i), 1._dp)
       syq(3,i) = MODULO(syq(3,i), 1._dp)
       syq(:,i) = syq(:,i) * (/nq1, nq2, nq3/)
       ioWRITE(stdout,'(i4,3i3,l2)') i, NINT(syq(:,i)), (i>symq(iq)%nq_star)
    ENDDO

  ENDDO Q_POINTS_LOOP

  !
  ! Number of degrees of freedom for the entire grid:
  nph = SUM(rank)
  ioWRITE(stdout, '("=====================")')
  ioWRITE(stdout, '(5x,a,2i5)') "TOTAL number of degrees of freedom", nph  
  
  ! Allocate a vector to hold the decomposed phonons over the entire grid
  ! I need single vector in order to do minimization, otherwise a derived
  ! type would be more handy
  ALLOCATE(ph_coefficients(nph), ph_coefficients0(nph))
  iph = 0
  Q_POINTS_LOOP2 : &
  DO iq = 1, nq_wedge
    xq = symq(iq)%xq
    !IF(iq==1) xq=xq+1.d-6
    !
    ! Interpolate the system dynamical matrix at this q
    CALL fftinterp_mat2(xq, Si, fc, d2)
    ! Remove the mass factor, I cannot remove it before because the effective
    ! charges/long range interaction code assumes it is there
    d2 = multiply_mass_dyn(Si,d2)
    WRITE(998,'(i3,3f12.6)') iq, symq(iq)%xq
    WRITE(998,'(3(2f12.6,4x))') d2

    !
    ! Decompose the dynamical matrix over the symmetric basis at this q-point
    ioWRITE(stdout,'(2x,a)') "== DECOMPOSITION =="
    DO i = 1,rank(iq)
      iph = iph +1
      ph_coefficients(iph) = dotprodmat(3*Si%nat,d2, dmb(iq)%basis(:,:,i))
      ioWRITE(stdout,"(i3,1f12.6)") i, ph_coefficients(iph)
    ENDDO
    !
  ENDDO Q_POINTS_LOOP2
  !
  ph_coefficients0 = ph_coefficients
  !Si%lrigid = .false.
!-----------------------------------------------------------------------
  ! Variables that can be adjusted according to need ...
  !
  n_steps = input%nmax/num_procs ! total molecular dynamics steps TO READ
  first_step = input%nfirst ! start reading from this step
  n_skip = input%nskip !        ! number of steps to skip

  CALL read_md(input%md, input%e0, first_step, n_skip, n_steps,Si,fc,u,F_AI,tot_ene)

  mfcn = 3*Si%nat*fc%n_R 
  ALLOCATE(force_diff(mfcn))
  nfar = 0

  !ALLOCATE(fjac(mfcn, nph), ipvt(nph), qtf(nph))
  !ALLOCATE(wa1(nph),wa2(nph),wa3(nph),wa4(mfcn))
  !
  ! Use complete lmdif for more control
  !ALLOCATE(metric(nph))
  !metric = ABS(ph_coefficients)
  !metric = 1._dp !(ph_coefficients)**2 !(ph_coefficients)**2
!  DO i = 1, nph
!    ph_coefficients(i) = ph_coefficients(i) + (0.5_dp-rand())*.1_dp
!  ENDDO
  !factor = 1.d-3
!CALL harmonic_force(n_steps, Si,fcout,u,F_HAR,h_energy)
! before minimization
  CALL minimize(mfcn, nph, ph_coefficients, force_diff, iswitch)
  OPEN(118,file="h_enr.dat0",status="unknown") 
  DO i = 1, n_steps
  !WRITE(117,*) "i_step = ",i
        WRITE(118,'(E14.8)') h_energy(i) !
  END DO
  CLOSE(118)
  ! where

  !ph_coefficients(3) =   ph_coefficients(3) *0.0_dp

  CALL ACRS0(nph,ph_coefficients, force_diff, minimize2)

  !CALL lmdif(minimize,mfcn,nph,ph_coefficients,force_diff,1.d-8,0.d0,0.d0,huge(1),0.d0, &
  !           metric,2,factor,0,iswitch,nfev,fjac, &
  !           mfcn,ipvt,qtf,wa1,wa2,wa3,wa4)
  !
  nfar = 0
  iswitch = 0
  CALL minimize(mfcn, nph, ph_coefficients, force_diff, iswitch)
  Si%lrigid = lrigid_save
  CALL write_fc2("matOUT.periodic", Si, fcout)

   ! Force ratio
   OPEN(116,file="force_ratio.dat",status="unknown") 
   DO i = 1, n_steps
   WRITE(116,*) "i_step = ",i
   DO j = 1, Si%nat*nqmax
      WRITE(116,'(3(3f14.9,5x))') F_HAR(:,j,i)/F_AI(:,j,i), F_HAR(:,j,i), F_AI(:,j,i)
      !WRITE(116,'(3(f14.9,5x))') NORM2(F_AI(:,j,i)), NORM2(F_HAR(:,j,i)), F_HAR(:,j,i)/F_AI(:,j,i)  
   END DO
   END DO
   CLOSE(116)
   ! 
   ! Harmonic energy
   ! 
   OPEN(117,file="h_enr.dat",status="unknown") 
   DO i = 1, n_steps
   !WRITE(117,*) "i_step = ",i
         WRITE(117,'(i5,3(E13.6, 3x))') i, h_energy(i), tot_ene(i), &
                                         EXP(-tot_ene(i)/(K_BOLTZMANN_RY*300.0_DP))
   END DO
   CLOSE(117)
   !
  nfar = 2
  CALL minimize(mfcn, nph, ph_coefficients, force_diff, iswitch)
  CALL write_fc2("matOUT.centered", Si, fcout)

  CALL t_minim%print()

  CALL stop_mpi()

  !write fcout to file (final result)
 ! ---- the program is over ---- !
 !
 CONTAINS
!-----------------------------------------------------------------------
 SUBROUTINE minimize(mfc, nph, ph_coef, fdiff2, iswitch)
  !-----------------------------------------------------------------------
  ! Calculates the square difference, fdiff2, btw harmonic and ab-initio
  ! forces for n_steps molecur dyanmics simulation 
  !
  USE tdph_module, ONLY : nfar
  USE mpi_thermal, ONLY : mpi_bsum
  IMPLICIT NONE
    INTEGER,INTENT(in)    :: mfc, nph
    REAL(DP),INTENT(in)   :: ph_coef(nph)
    REAL(DP),INTENT(out)  :: fdiff2(mfc)
    INTEGER,INTENT(inout) :: iswitch
  
    INTEGER :: nq_done, iph, iq, i, j, k
    INTEGER,SAVE :: iter = 0
    CHARACTER (LEN=6),  EXTERNAL :: int_to_char
    REAL(DP) :: chi2, kb, T, e0

    CALL t_minim%start()

  nq_done = 0
  iph = 0
  Q_POINTS_LOOP3 : &
  DO iq = 1, nq_wedge
    !
    ! Reconstruct the dynamical matrix from the coefficients
    d2 = 0._dp
    DO i = 1,rank(iq)
      iph = iph+1
      d2 = d2+ ph_coef(iph)*dmb(iq)%basis(:,:,i)
    ENDDO
    WRITE(999,'(i3,3f12.6)') iq,symq(iq)%xq
    WRITE(999,'(3(2f12.6,4x))') d2

    !
    IF(nq_done+symq(iq)%nq_trstar> nqmax) CALL errore("tdph","too many q-points",1)
    !
    ! Rotate the dynamical matrices to generate D(q) for every q in the star
    ALLOCATE(star_dyn(3*Si%nat,3*Si%nat, symq(iq)%nq_trstar))
    CALL make_qstar_d2 (d2, Si%at, Si%bg, Si%nat, symq(iq)%nsym, symq(iq)%s, &
                        symq(iq)%invs, symq(iq)%irt, symq(iq)%rtau, &
                        symq(iq)%nq_star, symq(iq)%sxq, symq(iq)%isq, &
                        symq(iq)%imq, symq(iq)%nq_trstar, star_dyn, &
                        star_wdyn(:,:,:,:,nq_done+1:nq_done+symq(iq)%nq_trstar))

    ! rebuild the full list of q vectors in the grid by concatenating all the stars
    xqmax(:,nq_done+1:nq_done+symq(iq)%nq_trstar) &
        = symq(iq)%sxq(:,1:symq(iq)%nq_trstar)

    nq_done = nq_done + symq(iq)%nq_trstar

    DEALLOCATE(star_dyn)

  ENDDO Q_POINTS_LOOP3

  IF(iph.ne.nph) CALL errore("minimize", "wrong iph", 1)
  !
  CALL quter(nq1, nq2, nq3, Si%nat,Si%tau,Si%at,Si%bg, star_wdyn, xqmax, fcout, nfar)
  IF(nfar.ne.0) RETURN
  !
  ! READ atomic positions, forces, etc, and compute harmonic force and energy
  CALL harmonic_force(n_steps, Si,fcout,u,F_HAR,h_energy)
  !CALL read_md(first_step, n_skip, n_steps,Si,fc,u,F_AI)
  !IF(.not.ALLOCATED(f_harm)) ALLOCATE(f_harm(....))
  !IF(.NOT.ALLOCATED(fdiff2)) ALLOCATE(fdiff2(nf))
  !
  !WRITE(*,'(2(3f14.6))') F_HAR, F_AI
  !print*, "-->", nf, size(fdiff2), size(F_HAR), size(F_AI)
  !e0 = 40.31064793_dp
  !e0 = 136.04711842_dp
  e0 = 322.48516551
  T = 300.0_DP
  kb = K_BOLTZMANN_RY*T
  !
  fdiff2 = 0._dp

  DO i = 1, n_steps
    !fdiff2 = fdiff2 + RESHAPE( ABS(F_HAR(:,:,i) - F_AI(:,:,i)), (/ mfc /) )
    !fdiff2 = fdiff2 + ( NORM2(F_HAR(:,:,i)) - NORM2(F_AI(:,:,i)))
    !
    ! x weight = exp(-E_ai/kbT)
    !fdiff2 = fdiff2 + RESHAPE( (ABS(F_HAR(:,:,i) - F_AI(:,:,i))*EXP(-tot_ene(i)) ), (/ mfc /) )
    fdiff2 = fdiff2 + (h_energy(i)-tot_ene(i))
  ENDDO


  !DO i = 1, n_steps
  !  DO j = 1, Si%nat*fc%n_R
  !  fdiff2(j) = fdiff2(j) + SQRT(SUM((F_HAR(:,j,i) - F_AI(:,j,i))**2))
  ! + RESHAPE( ABS(F_HAR(:,:,i) - F_AI(:,:,i)), (/ mfc /) )
  ! ENDDO
  !ENDDO
  CALL mpi_bsum(mfc, fdiff2) 

  !IF(ANY(ABS(ph_coefficients)>2._dp)) fdiff2 = 100._dp
  ! iswitch =1 are real steps, while iswitch=2 are evaluations used to compute the gradient
  IF(iswitch==1)THEN
    iter = iter+1
    chi2 = SUM(fdiff2**2)/(n_steps*num_procs)
    ioWRITE(*,'(i10,e12.2)') iter, chi2
    ioWRITE(9999, "(i10,9999f12.6)") iter, chi2, ph_coefficients
    ! Every 1000 steps have a look
    IF(MODULO(iter,1000)==0) CALL write_fc2("matOUT.iter_"//TRIM(int_to_char(iter)), Si, fcout)
  ENDIF

  CALL t_minim%stop()
  !
  END SUBROUTINE
  !

!-----------------------------------------------------------------------
  SUBROUTINE minimize2(ph_coef, nph, fdiff2)
    !-----------------------------------------------------------------------
    ! Calculates the square difference, fdiff2, btw harmonic and ab-initio
    ! forces for n_steps molecur dyanmics simulation 
    !
    USE tdph_module, ONLY : nfar
    USE mpi_thermal, ONLY : mpi_bsum
    IMPLICIT NONE
      INTEGER,INTENT(in)    :: nph
      REAL(DP),INTENT(in)   :: ph_coef(nph)
      REAL(DP),INTENT(out)  :: fdiff2
    
      INTEGER :: nq_done, iph, iq, i, j, k
      INTEGER,SAVE :: iter = 0
      CHARACTER (LEN=6),  EXTERNAL :: int_to_char
      REAL(DP) :: chi2, kb, T, e0
  
      CALL t_minim%start()
  
    nq_done = 0
    iph = 0
    Q_POINTS_LOOP3 : &
    DO iq = 1, nq_wedge
      !
      ! Reconstruct the dynamical matrix from the coefficients
      d2 = 0._dp
      DO i = 1,rank(iq)
        iph = iph+1
        d2 = d2+ ph_coef(iph)*dmb(iq)%basis(:,:,i)
      ENDDO
      WRITE(999,'(i3,3f12.6)') iq,symq(iq)%xq
      WRITE(999,'(3(2f12.6,4x))') d2
  
      !
      IF(nq_done+symq(iq)%nq_trstar> nqmax) CALL errore("tdph","too many q-points",1)
      !
      ! Rotate the dynamical matrices to generate D(q) for every q in the star
      ALLOCATE(star_dyn(3*Si%nat,3*Si%nat, symq(iq)%nq_trstar))
      CALL make_qstar_d2 (d2, Si%at, Si%bg, Si%nat, symq(iq)%nsym, symq(iq)%s, &
                          symq(iq)%invs, symq(iq)%irt, symq(iq)%rtau, &
                          symq(iq)%nq_star, symq(iq)%sxq, symq(iq)%isq, &
                          symq(iq)%imq, symq(iq)%nq_trstar, star_dyn, &
                          star_wdyn(:,:,:,:,nq_done+1:nq_done+symq(iq)%nq_trstar))
  
      ! rebuild the full list of q vectors in the grid by concatenating all the stars
      xqmax(:,nq_done+1:nq_done+symq(iq)%nq_trstar) &
          = symq(iq)%sxq(:,1:symq(iq)%nq_trstar)
  
      nq_done = nq_done + symq(iq)%nq_trstar
  
      DEALLOCATE(star_dyn)
  
    ENDDO Q_POINTS_LOOP3
  
    IF(iph.ne.nph) CALL errore("minimize", "wrong iph", 1)
    !
    CALL quter(nq1, nq2, nq3, Si%nat,Si%tau,Si%at,Si%bg, star_wdyn, xqmax, fcout, nfar)
    IF(nfar.ne.0) RETURN
    !
    ! READ atomic positions, forces, etc, and compute harmonic forces
    CALL harmonic_force(n_steps, Si,fcout,u,F_HAR,h_energy)
    !
    fdiff2 = 0._dp
  
    DO i = 1, n_steps
      SELECT CASE(input%fit_type)
      CASE('force', 'forces')
        fdiff2 = fdiff2 + SUM((F_HAR(:,:,i) - F_AI(:,:,i))**2 )
      CASE('energy')
        fdiff2 = fdiff2 + (h_energy(i)-tot_ene(i))**2
      CASE('thforce')
        fdiff2 = fdiff2 + SUM( (F_HAR(:,:,i) - F_AI(:,:,i))**2 )*EXP(-tot_ene(i))
      CASE DEFAULT
        CALL errore("tdph", 'unknown chi2 method', 1)
      END SELECT
    ENDDO

    iter = iter+1
    chi2 = SQRT(fdiff2)/(n_steps*num_procs)
    ioWRITE(*,'(i10,e12.2)') iter, chi2
    ioWRITE(9999, "(i10,9999f12.6)") iter, chi2, ph_coef
    ! Every 1000 steps have a look
    IF(input%nprint>0 .and. MODULO(iter,input%nprint)==0) CALL write_fc2("matOUT.iter_"//TRIM(int_to_char(iter)), Si, fcout)
    !ENDIF
  
    CALL t_minim%stop()
    !
    END SUBROUTINE minimize2
  
  !----------------------------------------------------------------------------
 END PROGRAM tdph
!------------------------------------------------------------------------------
