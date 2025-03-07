"
I'm a RabbitMQ Client.

I know how to connect to Rabbit MQ.
My subclasses will act as different roles depending on the system needs.
"
Class {
	#name : 'RabbitMQClient',
	#superclass : 'Object',
	#instVars : [
		'connection',
		'channel',
		'options'
	],
	#category : 'Ansible-RabbitMQ',
	#package : 'Ansible-RabbitMQ'
}

{ #category : 'testing' }
RabbitMQClient class >> isAbstract [

	<ignoreForCoverage>
	^ self = RabbitMQClient
]

{ #category : 'publishing' }
RabbitMQClient >> channel [

  ^ channel
]

{ #category : 'private - configuring' }
RabbitMQClient >> connectivityErrors [

  ^ NetworkError , AmqpDisconnectedError , ExpectedSocketFailure
]

{ #category : 'initialization' }
RabbitMQClient >> createAMQPConnection [

	| builder |

	builder := AmqpConnectionBuilder usingAMQP091Protocol.
	builder hostname: ( options at: #hostname ifAbsent: [ 'localhost' ] ).
	builder portNumber: ( options at: #port ifAbsent: [ 5672 ] ).
	builder username: ( options at: #username ifAbsent: [ 'guest' ] ).
	builder password: ( options at: #password ifAbsent: [ 'guest' ] ).
	options at: 'extraClientProperties' ifPresent: [ :extraProperties |
			extraProperties keysAndValuesDo: [ :propertyName :propertyValue |
					builder atClientProperty: propertyName put: propertyValue ]
		].

	^ builder build
]

{ #category : 'private' }
RabbitMQClient >> ensureChannelOpen [

	| reconnect |

	reconnect := [
	             self ensureConnectedAndOpen.
	             channel := connection createChannel
	             ].
	channel ifNil: reconnect ifNotNil: [ channel whenOpenDo: [  ] whenClosedDo: reconnect ]
]

{ #category : 'private' }
RabbitMQClient >> ensureConnectedAndOpen [

	| createConnection |

	createConnection := [
		self
			try: [
				connection := self createAMQPConnection.
				connection open]
			onConnectivityErrorDo: [:attemptNumber :error |
				self logFailedConnectionAttempt: attemptNumber dueTo: error]].

	connection
		ifNil: createConnection
		ifNotNil: [connection whenConnected: [] whenNot: createConnection].
		
	connection
		whenOpen: []
		whenNot: [connection open]
]

{ #category : 'initialization' }
RabbitMQClient >> initialize [

  options := Dictionary new
]

{ #category : 'private - connecting' }
RabbitMQClient >> logFailedConnectionAttempt: attemptNumber dueTo: error [

	LogRecord emitError: ( 'Attempt #<1p>/<2p> to connect to RabbitMQ failed: <3s>'
			  expandMacrosWith: attemptNumber
			  with: self retryCount 
			  with: error messageText )
]

{ #category : 'private - configuring' }
RabbitMQClient >> retryCount [

  ^ options at: #maximumConnectionAttemps ifAbsent: [ 3 ]
]

{ #category : 'private - testing' }
RabbitMQClient >> shouldLogDebuggingInfo [

  ^ options at: #enableDebuggingLogs ifAbsent: [ false ]
]

{ #category : 'controlling' }
RabbitMQClient >> start [

	self ensureChannelOpen
]

{ #category : 'controlling' }
RabbitMQClient >> stop [

	connection
		ifNil: []
		ifNotNil: [
			connection
				whenConnected: [connection close]
				whenNot: [LogRecord emitWarning: 'RabbitMQ connection was already closed.']]
]

{ #category : 'private - accessing' }
RabbitMQClient >> timeframeBetweenAttempts [

  ^ Duration milliSeconds: ( options at: #timeSlotBetweenConnectionRetriesInMs ifAbsent: [ 3000 ] )
]

{ #category : 'private - connecting' }
RabbitMQClient >> try: aBlock onConnectivityErrorDo: failBlock [

  Retry value: aBlock configuredBy: [ :retry |
      retry
        upTo: self retryCount;
        backoffExponentiallyWithTimeSlot: self timeframeBetweenAttempts;
        on: self connectivityErrors evaluating: failBlock.
      options at: #retry ifPresent: [ :action | action value: retry ]
    ]
]
