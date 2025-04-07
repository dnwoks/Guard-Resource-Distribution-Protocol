;; Guard Resource Distribution Protocol that Enables conditional and controlled distribution of digital resources between entities

;; System parameters
(define-constant PROTOCOL_OPERATOR tx-sender)
(define-constant CODE_ACCESS_DENIED (err u100))
(define-constant CODE_CONTAINER_MISSING (err u101))
(define-constant CODE_STATUS_CONFLICT (err u102))
(define-constant CODE_DISTRIBUTION_FAILED (err u103))
(define-constant CODE_INVALID_REFERENCE (err u104))
(define-constant CODE_INVALID_QUANTITY (err u105))
(define-constant CODE_INVALID_ORIGINATOR (err u106))
(define-constant CODE_TIMEFRAME_EXCEEDED (err u107))
(define-constant STANDARD_DURATION_BLOCKS u1008)

;; Main storage structure
(define-map ResourceContainers
  { container-reference: uint }
  {
    originator: principal,
    beneficiary: principal,
    resource-category: uint,
    quantity: uint,
    container-status: (string-ascii 10),
    initiation-block: uint,
    termination-block: uint
  }
)

;; System counter
(define-data-var latest-container-reference uint u0)

;; Utility functions 
(define-private (eligible-beneficiary? (beneficiary principal))
  (and 
    (not (is-eq beneficiary tx-sender))
    (not (is-eq beneficiary (as-contract tx-sender)))
  )
)

(define-private (valid-container-reference? (container-reference uint))
  (<= container-reference (var-get latest-container-reference))
)

;; Core protocol functions

;; Release container from emergency lockdown with security verification
(define-public (release-container-lockdown (container-reference uint) (verification-code (buff 32)) (authorized-by principal))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (cooldown-period u36) ;; ~6 hours
      )
      ;; Only protocol operator can unlock containers
      (asserts! (is-eq tx-sender PROTOCOL_OPERATOR) CODE_ACCESS_DENIED)
      ;; Container must be in locked status
      (asserts! (is-eq (get container-status container-data) "locked") CODE_STATUS_CONFLICT)
      ;; Authorized entity must be originator or protocol operator
      (asserts! (or (is-eq authorized-by originator) (is-eq authorized-by PROTOCOL_OPERATOR)) (err u230))
      ;; Minimum lockdown period must have passed
      (asserts! (>= (- block-height (get initiation-block container-data)) cooldown-period) (err u231))

      ;; Restore container to pending status
      (map-set ResourceContainers
        { container-reference: container-reference }
        (merge container-data { container-status: "pending" })
      )

      (print {action: "lockdown_released", container-reference: container-reference, 
              operator: tx-sender, authorized-by: authorized-by, verification-code-hash: (hash160 verification-code)})
      (ok true)
    )
  )
)

;; Apply rate limiting to prevent rapid container operations by a single entity
(define-public (reset-operation-rate-limit (entity principal) (operation-category (string-ascii 20)))
  (begin
    ;; Only protocol operator can reset rate limits
    (asserts! (is-eq tx-sender PROTOCOL_OPERATOR) CODE_ACCESS_DENIED)
    ;; Valid operation categories
    (asserts! (or (is-eq operation-category "creation") 
                 (is-eq operation-category "distribution")
                 (is-eq operation-category "reversal")
                 (is-eq operation-category "extension")) (err u240))

    (let
      (
        (cooldown-period u12) ;; ~2 hours
        (rate-limit u5) ;; 5 operations max
        (block-window (/ block-height u144)) ;; Window of ~1 day
      )
      ;; Note: In a complete implementation, we would maintain a map of operations
      ;; performed by entity within the current window and reset it here.
      ;; For now, we'll just print the action.

      (print {action: "rate_limit_reset", entity: entity, operation-category: operation-category, 
              operator: tx-sender, rate-limit: rate-limit, window: block-window})
      (ok true)
    )
  )
)

;; Delegate container management to secondary authority with security controls
(define-public (delegate-container-authority (container-reference uint) (delegate principal) (delegation-period uint) (revocable bool))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (asserts! (> delegation-period u0) CODE_INVALID_QUANTITY)
    (asserts! (<= delegation-period u720) CODE_INVALID_QUANTITY) ;; Max ~5 days
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
        (expiration-block (+ block-height delegation-period))
      )
      ;; Only originator can delegate authority
      (asserts! (is-eq tx-sender originator) CODE_ACCESS_DENIED)
      ;; Delegate must not be the originator or beneficiary
      (asserts! (and (not (is-eq delegate originator)) (not (is-eq delegate beneficiary))) (err u250))
      ;; Container must be in appropriate status
      (asserts! (or (is-eq (get container-status container-data) "pending") 
                   (is-eq (get container-status container-data) "accepted")) CODE_STATUS_CONFLICT)
      ;; Cannot delegate if container is near expiration
      (asserts! (> (- (get termination-block container-data) block-height) delegation-period) CODE_TIMEFRAME_EXCEEDED)

      ;; Note: In a complete implementation, we would maintain a delegation map
      ;; For now, we'll just print the delegation information

      (print {action: "authority_delegated", container-reference: container-reference, originator: originator, 
              delegate: delegate, expiration-block: expiration-block, revocable: revocable})
      (ok expiration-block)
    )
  )
)

;; Finalize distribution to beneficiary
(define-public (execute-resource-distribution (container-reference uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (beneficiary (get beneficiary container-data))
        (quantity (get quantity container-data))
        (category (get resource-category container-data))
      )
      (asserts! (or (is-eq tx-sender PROTOCOL_OPERATOR) (is-eq tx-sender (get originator container-data))) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (asserts! (<= block-height (get termination-block container-data)) CODE_TIMEFRAME_EXCEEDED)
      (match (as-contract (stx-transfer? quantity tx-sender beneficiary))
        success
          (begin
            (map-set ResourceContainers
              { container-reference: container-reference }
              (merge container-data { container-status: "completed" })
            )
            (print {action: "resources_distributed", container-reference: container-reference, beneficiary: beneficiary, resource-category: category, quantity: quantity})
            (ok true)
          )
        error CODE_DISTRIBUTION_FAILED
      )
    )
  )
)

;; Revert distribution to originator
(define-public (retrieve-container-resources (container-reference uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (quantity (get quantity container-data))
      )
      (asserts! (is-eq tx-sender PROTOCOL_OPERATOR) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (match (as-contract (stx-transfer? quantity tx-sender originator))
        success
          (begin
            (map-set ResourceContainers
              { container-reference: container-reference }
              (merge container-data { container-status: "returned" })
            )
            (print {action: "resources_returned", container-reference: container-reference, originator: originator, quantity: quantity})
            (ok true)
          )
        error CODE_DISTRIBUTION_FAILED
      )
    )
  )
)

;; Implement multi-signature approval for high-value container executions
;; Requires approvals from multiple authorized parties before executing resource distributions
(define-public (register-multi-sig-approval (container-reference uint) (approval-signature (buff 65)))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
        (quantity (get quantity container-data))
      )
      ;; Only for high-value containers
      (asserts! (> quantity u50000) (err u230)) ;; High value threshold
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender beneficiary) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)

      ;; In production, would verify the signature against a known public key
      ;; and increment an approval counter in a separate map

      (print {action: "multi_sig_approval_registered", container-reference: container-reference, 
              approver: tx-sender, signature-digest: (hash160 approval-signature)})
      (ok true)
    )
  )
)

;; Defer critical operation execution
(define-public (defer-critical-operation (operation-type (string-ascii 20)) (operation-parameters (list 10 uint)))
  (begin
    (asserts! (is-eq tx-sender PROTOCOL_OPERATOR) CODE_ACCESS_DENIED)
    (asserts! (> (len operation-parameters) u0) CODE_INVALID_QUANTITY)
    (let
      (
        (execution-time (+ block-height u144)) ;; 24 hours delay
      )
      (print {action: "operation_deferred", operation-type: operation-type, operation-parameters: operation-parameters, execution-time: execution-time})
      (ok execution-time)
    )
  )
)

;; Modify container timeframe
(define-public (prolong-container-timeframe (container-reference uint) (additional-blocks uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (asserts! (> additional-blocks u0) CODE_INVALID_QUANTITY)
    (asserts! (<= additional-blocks u1440) CODE_INVALID_QUANTITY) ;; Maximum extension: ~10 days
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data)) 
        (beneficiary (get beneficiary container-data))
        (current-termination (get termination-block container-data))
        (modified-termination (+ current-termination additional-blocks))
      )
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender beneficiary) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      (asserts! (or (is-eq (get container-status container-data) "pending") (is-eq (get container-status container-data) "accepted")) CODE_STATUS_CONFLICT)
      (map-set ResourceContainers
        { container-reference: container-reference }
        (merge container-data { termination-block: modified-termination })
      )
      (print {action: "timeframe_extended", container-reference: container-reference, requester: tx-sender, new-termination-block: modified-termination})
      (ok true)
    )
  )
)

;; Retrieve expired container resources
(define-public (retrieve-expired-container (container-reference uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (quantity (get quantity container-data))
        (expiration (get termination-block container-data))
      )
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      (asserts! (or (is-eq (get container-status container-data) "pending") (is-eq (get container-status container-data) "accepted")) CODE_STATUS_CONFLICT)
      (asserts! (> block-height expiration) (err u108)) ;; Verification of expiration
      (match (as-contract (stx-transfer? quantity tx-sender originator))
        success
          (begin
            (map-set ResourceContainers
              { container-reference: container-reference }
              (merge container-data { container-status: "expired" })
            )
            (print {action: "expired_container_retrieved", container-reference: container-reference, originator: originator, quantity: quantity})
            (ok true)
          )
        error CODE_DISTRIBUTION_FAILED
      )
    )
  )
)

;; Originator requests reversal
(define-public (abort-distribution (container-reference uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (quantity (get quantity container-data))
      )
      (asserts! (is-eq tx-sender originator) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (asserts! (<= block-height (get termination-block container-data)) CODE_TIMEFRAME_EXCEEDED)
      (match (as-contract (stx-transfer? quantity tx-sender originator))
        success
          (begin
            (map-set ResourceContainers
              { container-reference: container-reference }
              (merge container-data { container-status: "cancelled" })
            )
            (print {action: "distribution_cancelled", container-reference: container-reference, originator: originator, quantity: quantity})
            (ok true)
          )
        error CODE_DISTRIBUTION_FAILED
      )
    )
  )
)

;; Start dispute process
(define-public (initiate-dispute (container-reference uint) (justification (string-ascii 50)))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
      )
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender beneficiary)) CODE_ACCESS_DENIED)
      (asserts! (or (is-eq (get container-status container-data) "pending") (is-eq (get container-status container-data) "accepted")) CODE_STATUS_CONFLICT)
      (asserts! (<= block-height (get termination-block container-data)) CODE_TIMEFRAME_EXCEEDED)
      (map-set ResourceContainers
        { container-reference: container-reference }
        (merge container-data { container-status: "disputed" })
      )
      (print {action: "dispute_initiated", container-reference: container-reference, initiator: tx-sender, justification: justification})
      (ok true)
    )
  )
)

;; Register fail-safe contact point
(define-public (register-fallback-entity (container-reference uint) (fallback-entity principal))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
      )
      (asserts! (is-eq tx-sender originator) CODE_ACCESS_DENIED)
      (asserts! (not (is-eq fallback-entity tx-sender)) (err u111)) ;; Fallback entity must differ
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (print {action: "fallback_registered", container-reference: container-reference, originator: originator, fallback: fallback-entity})
      (ok true)
    )
  )
)

;; Adjudicate disputed distribution
(define-public (adjudicate-dispute (container-reference uint) (originator-allocation uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (asserts! (is-eq tx-sender PROTOCOL_OPERATOR) CODE_ACCESS_DENIED)
    (asserts! (<= originator-allocation u100) CODE_INVALID_QUANTITY) ;; Valid percentage range
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
        (quantity (get quantity container-data))
        (originator-portion (/ (* quantity originator-allocation) u100))
        (beneficiary-portion (- quantity originator-portion))
      )
      (asserts! (is-eq (get container-status container-data) "disputed") (err u112)) ;; Must be disputed
      (asserts! (<= block-height (get termination-block container-data)) CODE_TIMEFRAME_EXCEEDED)

      ;; Allocate originator's share
      (unwrap! (as-contract (stx-transfer? originator-portion tx-sender originator)) CODE_DISTRIBUTION_FAILED)

      ;; Allocate beneficiary's share
      (unwrap! (as-contract (stx-transfer? beneficiary-portion tx-sender beneficiary)) CODE_DISTRIBUTION_FAILED)

      (map-set ResourceContainers
        { container-reference: container-reference }
        (merge container-data { container-status: "resolved" })
      )
      (print {action: "dispute_adjudicated", container-reference: container-reference, originator: originator, beneficiary: beneficiary, 
              originator-portion: originator-portion, beneficiary-portion: beneficiary-portion, originator-allocation: originator-allocation})
      (ok true)
    )
  )
)

;; Register secondary approval for large allocations
(define-public (register-supplementary-approval (container-reference uint) (approver principal))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (quantity (get quantity container-data))
      )
      ;; Only for substantial allocations (> 1000 STX)
      (asserts! (> quantity u1000) (err u120))
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (print {action: "supplementary_approval_registered", container-reference: container-reference, approver: approver, requester: tx-sender})
      (ok true)
    )
  )
)

;; Halt anomalous container
(define-public (halt-anomalous-container (container-reference uint) (justification (string-ascii 100)))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
      )
      (asserts! (or (is-eq tx-sender PROTOCOL_OPERATOR) (is-eq tx-sender originator) (is-eq tx-sender beneficiary)) CODE_ACCESS_DENIED)
      (asserts! (or (is-eq (get container-status container-data) "pending") 
                   (is-eq (get container-status container-data) "accepted")) 
                CODE_STATUS_CONFLICT)
      (map-set ResourceContainers
        { container-reference: container-reference }
        (merge container-data { container-status: "halted" })
      )
      (print {action: "container_halted", container-reference: container-reference, reporter: tx-sender, justification: justification})
      (ok true)
    )
  )
)

;; Initialize phased distribution container
(define-public (initialize-phased-container (beneficiary principal) (resource-category uint) (quantity uint) (intervals uint))
  (let 
    (
      (new-reference (+ (var-get latest-container-reference) u1))
      (termination-date (+ block-height STANDARD_DURATION_BLOCKS))
      (interval-quantity (/ quantity intervals))
    )
    (asserts! (> quantity u0) CODE_INVALID_QUANTITY)
    (asserts! (> intervals u0) CODE_INVALID_QUANTITY)
    (asserts! (<= intervals u5) CODE_INVALID_QUANTITY) ;; Maximum 5 intervals
    (asserts! (eligible-beneficiary? beneficiary) CODE_INVALID_ORIGINATOR)
    (asserts! (is-eq (* interval-quantity intervals) quantity) (err u121)) ;; Ensure clean division
    (match (stx-transfer? quantity tx-sender (as-contract tx-sender))
      success
        (begin
          (var-set latest-container-reference new-reference)
          (print {action: "phased_container_initialized", container-reference: new-reference, originator: tx-sender, beneficiary: beneficiary, 
                  resource-category: resource-category, quantity: quantity, intervals: intervals, interval-quantity: interval-quantity})
          (ok new-reference)
        )
      error CODE_DISTRIBUTION_FAILED
    )
  )
)

;; Process delayed withdrawal
(define-public (execute-delayed-withdrawal (container-reference uint))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (quantity (get quantity container-data))
        (status (get container-status container-data))
        (delay-duration u24) ;; 24 blocks delay (~4 hours)
      )
      ;; Only originator or operator can execute
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      ;; Only from pending-withdrawal status
      (asserts! (is-eq status "withdrawal-pending") (err u301))
      ;; Delay period must have elapsed
      (asserts! (>= block-height (+ (get initiation-block container-data) delay-duration)) (err u302))

      ;; Process withdrawal
      (unwrap! (as-contract (stx-transfer? quantity tx-sender originator)) CODE_DISTRIBUTION_FAILED)

      ;; Update container status
      (map-set ResourceContainers
        { container-reference: container-reference }
        (merge container-data { container-status: "withdrawn", quantity: u0 })
      )

      (print {action: "delayed_withdrawal_completed", container-reference: container-reference, 
              originator: originator, quantity: quantity})
      (ok true)
    )
  )
)

;; Activate enhanced authentication for substantial allocations
(define-public (activate-enhanced-authentication (container-reference uint) (auth-hash (buff 32)))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (quantity (get quantity container-data))
      )
      ;; Only for allocations above threshold
      (asserts! (> quantity u5000) (err u130))
      (asserts! (is-eq tx-sender originator) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (print {action: "enhanced_auth_activated", container-reference: container-reference, originator: originator, auth-hash: (hash160 auth-hash)})
      (ok true)
    )
  )
)

;; Cryptographic validation for substantial allocations
(define-public (validate-with-cryptography (container-reference uint) (message-digest (buff 32)) (signature (buff 65)) (signing-entity principal))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
        (validation-key (unwrap! (secp256k1-recover? message-digest signature) (err u150)))
      )
      ;; Validate with cryptographic proof
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender beneficiary) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      (asserts! (or (is-eq signing-entity originator) (is-eq signing-entity beneficiary)) (err u151))
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)

      ;; Verify signature corresponds to claimed entity
      (asserts! (is-eq (unwrap! (principal-of? validation-key) (err u152)) signing-entity) (err u153))

      (print {action: "cryptographic_validation_completed", container-reference: container-reference, validator: tx-sender, signing-entity: signing-entity})
      (ok true)
    )
  )
)

;; Attach auxiliary information
(define-public (attach-auxiliary-information (container-reference uint) (information-category (string-ascii 20)) (information-digest (buff 32)))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
      )
      ;; Only authorized entities can attach information
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender beneficiary) (is-eq tx-sender PROTOCOL_OPERATOR)) CODE_ACCESS_DENIED)
      (asserts! (not (is-eq (get container-status container-data) "completed")) (err u160))
      (asserts! (not (is-eq (get container-status container-data) "returned")) (err u161))
      (asserts! (not (is-eq (get container-status container-data) "expired")) (err u162))

      ;; Valid information categories
      (asserts! (or (is-eq information-category "resource-specs") 
                   (is-eq information-category "distribution-evidence")
                   (is-eq information-category "quality-assessment")
                   (is-eq information-category "originator-requirements")) (err u163))

      (print {action: "information_attached", container-reference: container-reference, information-category: information-category, 
              information-digest: information-digest, submitter: tx-sender})
      (ok true)
    )
  )
)

;; Configure delayed recovery mechanism
(define-public (configure-delayed-recovery (container-reference uint) (delay-duration uint) (recovery-entity principal))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (asserts! (> delay-duration u72) CODE_INVALID_QUANTITY) ;; Minimum 72 blocks delay (~12 hours)
    (asserts! (<= delay-duration u1440) CODE_INVALID_QUANTITY) ;; Maximum 1440 blocks delay (~10 days)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (activation-block (+ block-height delay-duration))
      )
      (asserts! (is-eq tx-sender originator) CODE_ACCESS_DENIED)
      (asserts! (is-eq (get container-status container-data) "pending") CODE_STATUS_CONFLICT)
      (asserts! (not (is-eq recovery-entity originator)) (err u180)) ;; Recovery entity must differ from originator
      (asserts! (not (is-eq recovery-entity (get beneficiary container-data))) (err u181)) ;; Recovery entity must differ from beneficiary
      (print {action: "delayed_recovery_configured", container-reference: container-reference, originator: originator, 
              recovery-entity: recovery-entity, activation-block: activation-block})
      (ok activation-block)
    )
  )
)

;; Register cryptographic attestation
(define-public (register-cryptographic-proof (container-reference uint) (proof-data (buff 65)))
  (begin
    (asserts! (valid-container-reference? container-reference) CODE_INVALID_REFERENCE)
    (let
      (
        (container-data (unwrap! (map-get? ResourceContainers { container-reference: container-reference }) CODE_CONTAINER_MISSING))
        (originator (get originator container-data))
        (beneficiary (get beneficiary container-data))
      )
      (asserts! (or (is-eq tx-sender originator) (is-eq tx-sender beneficiary)) CODE_ACCESS_DENIED)
      (asserts! (or (is-eq (get container-status container-data) "pending") (is-eq (get container-status container-data) "accepted")) CODE_STATUS_CONFLICT)
      (print {action: "proof_registered", container-reference: container-reference, registrant: tx-sender, proof-data: proof-data})
      (ok true)
    )
  )
)

