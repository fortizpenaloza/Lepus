Class {
	#name : 'AmqpConnection',
	#superclass : 'Object',
	#instVars : [
		'socket',
		'codec',
		'credentials',
		'parameters',
		'virtualHost',
		'isOpen',
		'channels',
		'nextChannel',
		'protocolClass',
		'heartbeatSender',
		'hostname',
		'socketConnectionStatus',
		'portNumber',
		'extraClientProperties'
	],
	#category : 'Ansible-Protocol-Core',
	#package : 'Ansible-Protocol-Core'
}

{ #category : 'instance creation' }
AmqpConnection class >> to: aHostname
	over: aPort
	using: aProtocolVersion
	with: aConnectionCredentialCollection
	parameterizedBy: aConnectionParameterCollection
	extraProperties: aClientPropertyCollection [

	^ self new
		  initializeTo: aHostname
		  over: aPort
		  using: aProtocolVersion
		  with: aConnectionCredentialCollection
		  parameterizedBy: aConnectionParameterCollection
		  extraProperties: aClientPropertyCollection
]

{ #category : 'connection-handling' }
AmqpConnection >> assertChannelOpen: channelNumber [

	self assertSocketConnected.
	^ ( channels at: channelNumber ) assertChannelOpen
]

{ #category : 'connection-handling' }
AmqpConnection >> assertSocketConnected [

  ( socket isConnected and: [ socket isOtherEndClosed not ] ) ifFalse: [
      AmqpDisconnectedError signal: 'Connection closed' ].

  ^ true
]

{ #category : 'connection-handling' }
AmqpConnection >> becomeCloseAfter: aBlock [

  | closingMethod |
  isOpen ifTrue: [
      [
        closingMethod := aBlock value.
        channels valuesDo: [ :ch | ch internalClose: closingMethod ]
      ] ensure: [
          LogRecord emitInfo: ( 'AMQP connection <1s> closed due to <2s>'
                expandMacrosWith: self connectionPairsDescription
                with: closingMethod replyText ).
          [ socket close ]
            on: ExpectedSocketFailure
            do: [ :error | 
					" If the socket was unexpectedly closed, trying to close it again 
					will raise a SocketError that we want to silence "
					error return ].
          isOpen := false.
          socketConnectionStatus := ClosedSocketConnection dueTo: closingMethod replyText.
          heartbeatSender stop.
        ]
    ]
]

{ #category : 'connection-handling' }
AmqpConnection >> close [

  self becomeCloseAfter: [
      | connectionClose |
      connectionClose := self protocolClass connectionCloseMethod new
                           replyCode: self protocolClass replySuccess;
                           replyText: 'Normal shutdown';
                           classId: 0;
                           methodId: 0.
      self
        rpc: connectionClose
        onChannel: 0
        ifConnectionClosesWhileWaitingReplyDo: [ :signal | "https://www.rabbitmq.com/amqp-0-9-1-reference.html#connection.close-ok A peer that detects a socket closure without having received a Close-Ok handshake method SHOULD log the error. - jvanecek"
            LogRecord emitWarning:
              ( 'AMQP connection <1s> closed while waiting for the close-ok reply'
                  expandMacrosWith: self connectionPairsDescription ).
            signal return
          ].
      connectionClose
    ]
]

{ #category : 'accessing' }
AmqpConnection >> codec [

	^ codec
]

{ #category : 'accessing' }
AmqpConnection >> connectionPairsDescription [

  ^ 'localhost:<1p>-><2s>:<3p>'
      expandMacrosWith: self localPortDescription
      with: hostname
      with: portNumber
]

{ #category : 'connection-handling' }
AmqpConnection >> createChannel [

	| handler |

	self assertSocketConnected.
	handler := AmqpChannelHandler new connection: self.
	^ AmqpChannel using: handler
]

{ #category : 'accessing' }
AmqpConnection >> credentials [

	^ credentials
]

{ #category : 'connection-handling' }
AmqpConnection >> handleConnectionClose: cmd [

  self becomeCloseAfter: [
      self sendMethod: self protocolClass connectionCloseOkMethod new onChannel: 0.
      cmd method
    ]
]

{ #category : 'connection-handling' }
AmqpConnection >> hardCloseDescribedWith: aDescription [

  self becomeCloseAfter: [
      self protocolClass connectionCloseMethod new
        replyCode: self protocolClass internalError;
        replyText: aDescription
    ]
]

{ #category : 'initialization' }
AmqpConnection >> initialize [

	super initialize.
	virtualHost := '/'.
	isOpen := false.
	channels := Dictionary new.
	nextChannel := 0
]

{ #category : 'initialization' }
AmqpConnection >> initializeHeartbeatSender [

	heartbeatSender := AmqpHeartbeatSender keepingOpen: self
]

{ #category : 'initialization' }
AmqpConnection >> initializeSocketConnection [

  socket := Socket newTCP.
  [
    socket connectToHostNamed: hostname port: portNumber.
    socketConnectionStatus := SuccesfulSocketConnection new.

    LogRecord emitInfo:
      ( 'AMQP connection <1s> established successfully' expandMacrosWith:
          self connectionPairsDescription )
  ]
    on: NetworkError
    do: [ :error |
        socketConnectionStatus := ClosedSocketConnection dueTo: error.
        LogRecord emitInfo: ( 'AMQP connection to <1s>:<2s> failed to establish because <3s>'
              expandMacrosWith: hostname
              with: portNumber printString
              with: error printString ).
        error pass
      ]
]

{ #category : 'initialization' }
AmqpConnection >> initializeTo: aHostname
	over: aPort
	using: aProtocolVersion
	with: aConnectionCredentialCollection
	parameterizedBy: aConnectionParameterCollection
	extraProperties: aClientPropertyCollection [

	protocolClass := aProtocolVersion.
	hostname := aHostname.
	portNumber := aPort.
	credentials := aConnectionCredentialCollection.
	parameters := aConnectionParameterCollection.
	extraClientProperties := aClientPropertyCollection.

	self
		initializeSocketConnection;
		initializeHeartbeatSender
]

{ #category : 'private-opening' }
AmqpConnection >> installChannel0 [

	| channel |

	channel := AmqpChannelHandler new connection: self.
	channel mapEvent: self protocolClass connectionCloseMethod to: self selector: #handleConnectionClose:
]

{ #category : 'accessing' }
AmqpConnection >> localPortDescription [

  ^ socket isConnected then: [ socket localPort ] otherwise: [ 0 ]
]

{ #category : 'connection-handling' }
AmqpConnection >> mainLoopCycle [

	self withNextFrameDo: [ :nextFrame |
		( nextFrame isKindOf: AmqpHeartbeatFrame ) ifFalse: [
			( channels at: nextFrame channelNumber ) handleFrame: nextFrame ]
		]
]

{ #category : 'connection-handling' }
AmqpConnection >> nextChannel [

	| tries limit |

	tries := 0.
	limit := parameters channelMax.
	( limit isNil or: [ limit = 0 ] )
		ifTrue: [ limit := 32767 ].
	[ channels includesKey: nextChannel ]
		whileTrue: [ nextChannel := nextChannel + 1 rem: limit.
			tries := tries + 1.
			nextChannel = 0
				ifTrue: [ nextChannel := 1 ].
			tries > limit
				ifTrue: [ AmqpResourceError signal: 'No free channels' ]
			].
	^ nextChannel
]

{ #category : 'connection-handling' }
AmqpConnection >> nextFrame [

	| typeCode channel length frameType frame |

	[ 
	typeCode := codec nextOctet.
	typeCode ifNil: [ ^ nil ].
	channel := codec nextShort.
	length := codec nextLong.
	frameType := self protocolClass frameClassFor: typeCode.
	frameType notNil
		ifTrue: [ frame := frameType new.
			frame frameType: typeCode.
			frame channelNumber: channel.
			frame readFrom: self length: length.
			codec nextOctet = self protocolClass frameEnd
				ifFalse: [ AmqpProtocolSyntaxError signal: 'Missing frame end marker' ].
			^ frame
			]
	] repeat
]

{ #category : 'opening' }
AmqpConnection >> open [

	codec := AmqpCodec
		on:
			((SocketStream on: socket)
				noTimeout;
				binary;
				yourself).

	self
		sendProtocolHeader;
		startConnection;
		tuneConnection;
		openConnection.

	heartbeatSender startBeatingEvery: parameters heartbeat
]

{ #category : 'private-opening' }
AmqpConnection >> openConnection [


	self installChannel0.

	self
		rpc: (self protocolClass connectionOpenMethod new virtualHost: virtualHost)
		onChannel: 0.
		
	isOpen := true.
]

{ #category : 'connection-handling' }
AmqpConnection >> printOn: aStream [

  self
    whenConnected: [
        aStream nextPutAll:
          ( 'AMPQ Connection on <1s>' expandMacrosWith: self connectionPairsDescription ) ]
    whenNot: [ :reason |
      aStream nextPutAll: ( 'AMPQ Connection closed due to <1s>' expandMacrosWith: reason ) ]
]

{ #category : 'connection-handling' }
AmqpConnection >> protocolClass [

	^ protocolClass
]

{ #category : 'connection-handling' }
AmqpConnection >> resetChannel: channelNumber [

	channels removeKey: channelNumber ifAbsent: [  ]
]

{ #category : 'connection-handling' }
AmqpConnection >> rpc: aRequestMethod onChannel: aChannelNumber [

	^ self
		  rpc: aRequestMethod
		  onChannel: aChannelNumber
		  ifConnectionClosesWhileWaitingReplyDo: [ :signal | signal pass ]
]

{ #category : 'initialization' }
AmqpConnection >> rpc: aRequestMethod onChannel: aChannelNumber ifConnectionClosesWhileWaitingReplyDo: aBlock [

  ^ [
      | ch |
      ch := self assertChannelOpen: aChannelNumber.
      self sendMethod: aRequestMethod onChannel: aChannelNumber.
      ch waitForReply: aRequestMethod acceptableResponseClasses
    ]
      on: AmqpDisconnectedError , ConnectionClosed
      do: [ :signal | aBlock cull: signal ]
]

{ #category : 'connection-handling' }
AmqpConnection >> sendBodyFrameContaining: aByteArray startingAt: aStartingPosition onChannel: aChannelNumber [

	| length |

	length := aByteArray size min: parameters frameMax - 8.	"Seven bytes of header, plus one byte of footer."
	self
		sendFrame:
			( AmqpContentBodyFrame new
				frameType: protocolClass frameBody;
				channelNumber: aChannelNumber;
				fragment: ( aByteArray copyFrom: aStartingPosition to: aStartingPosition + length - 1 ) ).
	^ aStartingPosition + length
]

{ #category : 'connection-handling' }
AmqpConnection >> sendFrame: aFrame [

	aFrame encodeOn: codec.
	codec nextOctetPut: self protocolClass frameEnd
]

{ #category : 'connection-handling' }
AmqpConnection >> sendMethod: aMethod onChannel: aChannelNumber [

	self
		sendFrame:
			( AmqpMethodFrame new
				frameType: self protocolClass frameMethod;
				channelNumber: aChannelNumber;
				methodId: aMethod codecMethodId;
				method: aMethod ).
	codec flush
]

{ #category : 'connection-handling' }
AmqpConnection >> sendMethod: aMethod properties: aProperties body: aByteArray onChannel: channelNumber [

	| pos |

	self assertChannelOpen: channelNumber.
	self
		sendFrame:
			( AmqpMethodFrame new
				frameType: protocolClass frameMethod;
				channelNumber: channelNumber;
				methodId: aMethod codecMethodId;
				method: aMethod ).
	self
		sendFrame:
			( AmqpContentHeaderFrame new
				frameType: protocolClass frameHeader;
				channelNumber: channelNumber;
				classId: aProperties codecClassId;
				bodySize: aByteArray size;
				properties: aProperties ).
	pos := 1.
	[ pos <= aByteArray size ]
		whileTrue: [ pos := self sendBodyFrameContaining: aByteArray startingAt: pos onChannel: channelNumber ].
	codec flush
]

{ #category : 'private-opening' }
AmqpConnection >> sendProtocolHeader [

	codec nextPutAll: self protocolClass protocolHeader.
	codec flush
]

{ #category : 'accessing' }
AmqpConnection >> setChannel: aChannelNumber to: aChannelHandler [

	channels at: aChannelNumber put: aChannelHandler
]

{ #category : 'connection-handling' }
AmqpConnection >> socketConnectionStatus [

	^ socketConnectionStatus
]

{ #category : 'private-opening' }
AmqpConnection >> startConnection [

	self withNextFrameDo: [ :nextFrame |
			| response clientProperties |

			response := credentials responseFor: nextFrame method.
			response ifNil: [
					AmqpDisconnectedError signal: 'No acceptable SASL mechanism for the given credentials' ].
			clientProperties := Dictionary new
				                    at: 'product' put: 'RabbitMQ Smalltalk';
				                    yourself.
			extraClientProperties keysAndValuesDo: [ :key :value | clientProperties at: key put: value ].
			
			self
				sendMethod: ( self protocolClass connectionStartOkMethod new
						  clientProperties: clientProperties;
						  mechanism: response key;
						  response: response value )
				onChannel: 0.
			credentials := nil
		]
]

{ #category : 'private-opening' }
AmqpConnection >> tuneConnection [

	self withNextFrameDo: [ :nextFrame |
		parameters applyServerSettings: nextFrame method.
		self
			sendMethod: ( self protocolClass connectionTuneOkMethod new
					  channelMax: parameters channelMax;
					  frameMax: parameters frameMax;
					  heartbeat: parameters heartbeat )
			onChannel: 0
		]
]

{ #category : 'accessing' }
AmqpConnection >> virtualHost [

	^ virtualHost
]

{ #category : 'connection-handling' }
AmqpConnection >> waitForEvent [

  [ self assertSocketConnected ] whileTrue: [ self mainLoopCycle ]
]

{ #category : 'connection-handling' }
AmqpConnection >> whenConnected: aBlock whenNot: anotherBlock [

	^socketConnectionStatus whenConnected: aBlock whenNot: anotherBlock
]

{ #category : 'connection-handling' }
AmqpConnection >> whenOpen: aBlock whenNot: aClosedHandler [

	^isOpen then: aBlock otherwise: aClosedHandler
]

{ #category : 'connection-handling' }
AmqpConnection >> withNextFrameDo: aBlock [

	| nextFrame |

	nextFrame := self nextFrame.

	nextFrame
		ifNil: [
			self hardCloseDescribedWith: 'Failed retrieving next frame'.
			^ self
			]
		ifNotNil: aBlock
]
