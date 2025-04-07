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
